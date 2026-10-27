#include "Engine.h"

#include "Keys.h"

#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx/candidatelist.h>
#include <fcitx/globalconfig.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx-utils/keysym.h>
#include <fcitx/statusarea.h>
#include <fcitx/userinterfacemanager.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <ctime>
#include <fstream>

FCITX_DEFINE_LOG_CATEGORY(araso_log, "araso");
#define ARASO_DEBUG() FCITX_LOGC(araso_log, Debug)
#define ARASO_INFO() FCITX_LOGC(araso_log, Info)
#define ARASO_ERROR() FCITX_LOGC(araso_log, Error)

namespace araso {

namespace {

/// How long the capsule saying what a correction did stays (the Mac strip's).
constexpr uint64_t kLearnedShown = 1800 * 1000;
/// The first update check after starting, and how often after that (the check itself skips when
/// the last one was less than a day ago, or updates are off).
constexpr uint64_t kFirstCheck = 60ull * 1000 * 1000;
constexpr uint64_t kCheckEvery = 6ull * 3600 * 1000 * 1000;

uint64_t Now() { return fcitx::now(CLOCK_MONOTONIC); }

/// A candidate in the card; chosen with a click (the keys go to the session).
class ChoiceWord : public fcitx::CandidateWord {
public:
    ChoiceWord(Engine *engine, int index, fcitx::Text text, bool reading)
        : fcitx::CandidateWord(std::move(text)), engine_(engine), index_(index), reading_(reading) {}
    void select(fcitx::InputContext *ic) const override {
        if (reading_) engine_->pick(ic, index_);
        else engine_->choose(ic, index_);
    }

private:
    Engine *engine_;
    int index_;
    bool reading_;
};

/// The tag a reading shows, in the user's language (the strip's EN, KO, JA, MIX).
std::string Tag(const std::string &tag) {
    if (tag == "EN") return L("EN");
    if (tag == "KO") return L("KO");
    if (tag == "JA") return L("JA");
    if (tag == "MIX") return L("MIX");
    return tag;
}

}  // namespace

void MenuItemAction::activate(fcitx::InputContext *ic) {
    if (!item.empty()) engine_->menuSelect(ic, item);
}

Engine::Engine(fcitx::Instance *instance)
    : instance_(instance), factory_([](fcitx::InputContext &) { return new State(); }) {
    instance_->inputContextManager().registerProperty("arasoState", &factory_);
    std::string error;
    ready_ = Bridge::shared().start(error);
    if (!ready_) {
        ARASO_ERROR() << "Araso can't start: " << error;
    } else {
        ARASO_INFO() << "Araso " << Bridge::version() << " started (" << Bridge::bridgePath() << ")";
        // The models and the kanji dictionary, once fcitx5 is up, so the first key isn't slow.
        warmUp_ = instance_->eventLoop().addDeferEvent([](fcitx::EventSource *) {
            Bridge::shared().warmUp();
            return true;
        });
    }

    menuAction_.setShortText("Araso");
    menuAction_.setIcon("araso");
    menuAction_.setMenu(&menu_);
    instance_->userInterfaceManager().registerAction("araso-menu", &menuAction_);

    watchers_.emplace_back(instance_->watchEvent(
        fcitx::EventType::InputContextDestroyed, fcitx::EventWatcherPhase::PreInputMethod, [this](fcitx::Event &event) {
            auto &icEvent = static_cast<fcitx::InputContextEvent &>(event);
            auto *st = state(icEvent.inputContext());
            if (!st || !st->client) return;
            Json request = Json::object();
            request.set("op", "detach");
            request.set("client", st->client);
            Bridge::shared().request(request);
            clients_.erase(st->client);
            st->client = 0;
        }));

    // fcitx5 takes 한/영 (Hangul) as a key that turns the input method on and off, before the
    // input method sees it. In a field Araso types in, it is Araso's switch key, as on Windows
    // (where right Alt is a switch key); elsewhere, or when the session leaves it, fcitx5's.
    watchers_.emplace_back(instance_->watchEvent(
        fcitx::EventType::InputContextKeyEvent, fcitx::EventWatcherPhase::PreInputMethod, [this](fcitx::Event &event) {
            auto &keyEvent = static_cast<fcitx::KeyEvent &>(event);
            auto *ic = keyEvent.inputContext();
            if (keyEvent.isRelease() || keyEvent.rawKey().sym() != FcitxKey_Hangul || !ic ||
                instance_->inputMethod(ic) != "araso") return;
            if (const auto *entry = instance_->inputMethodManager().entry("araso")) keyEvent_(*entry, keyEvent);
        }));

    if (ready_) {
        listen();
        scheduleUpdateCheck(kFirstCheck);
        // fcitx5 starts every field in its first input method, a keyboard layout, until a trigger key
        // (Ctrl+Space) turns Araso on there; on macOS and Windows Araso types wherever it is the
        // input source. So fcitx5's Active By Default goes on once, the first time Araso starts; the
        // settings window turns it off and on after that.
        std::string marker = Bridge::supportFolder() + "/fcitx5-active-by-default";
        if (access(marker.c_str(), F_OK) != 0) {
            setActiveByDefault(true);
            mkdir(Bridge::supportFolder().c_str(), 0700);
            std::ofstream(marker) << "fcitx5's Active By Default was turned on once; araso-settings changes it.\n";
        }
    }
}

Engine::~Engine() {
    if (socket_ >= 0) {
        socketEvent_.reset();
        close(socket_);
        unlink((Bridge::socketFolder() + "/ime").c_str());
    }
}

State *Engine::state(fcitx::InputContext *ic) { return ic ? ic->propertyFor(&factory_) : nullptr; }

std::string Engine::app(fcitx::InputContext *ic) const {
    // The program's name as the frontend tells it (`firefox`, `org.gnome.TextEditor`), lowercase as
    // Windows' exe names are: apps.json keys it so.
    std::string name = ic->program();
    for (char &c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return name;
}

bool Engine::attached(fcitx::InputContext *ic, State *st) {
    if (!ready_ || !st) return false;
    if (st->client) return true;
    Json request = Json::object();
    request.set("op", "attach");
    std::string name = app(ic);
    if (!name.empty()) request.set("app", name);
    Json response = Bridge::shared().request(request);
    st->client = response["reply"]["client"].asInt();
    if (st->client) clients_[st->client] = ic->watch();
    return st->client != 0;
}

Json Engine::request(const char *op, fcitx::InputContext *ic, State *st, Json extra) {
    // The field as the app sent it last; the composition at its caret.
    bool known = ic->capabilityFlags().test(fcitx::CapabilityFlag::SurroundingText) && ic->surroundingText().isValid();
    if (known) {
        st->document.setSurrounding(true, ic->surroundingText().text(), ic->surroundingText().cursor());
    } else {
        st->document.setSurrounding(false);
    }
    extra.set("op", op);
    extra.set("client", st->client);
    std::string name = app(ic);
    if (!name.empty()) extra.set("app", name);
    extra.set("context", st->document.context(ic->capabilityFlags().test(fcitx::CapabilityFlag::Password)));
    return Bridge::shared().request(extra);
}

bool Engine::answer(fcitx::InputContext *ic, State *st, const Json &response) {
    if (response.has("error")) ARASO_DEBUG() << "request failed: " << response["error"].asString();
    const Json &reply = response["reply"];
    bool committed = false;
    auto edits = st->document.apply(reply["ops"]);
    for (const auto &edit : edits) {
        if (edit.kind == Document::Edit::Kind::Delete) {
            ic->deleteSurroundingText(edit.offset, edit.size);
        } else {
            ic->commitString(edit.text);
            committed = true;
        }
    }
    // What the app's surrounding text will say once it hears of the edits (deletions alone too), so
    // the next key doesn't see the field from before them.
    if (!edits.empty() && st->document.known()) {
        unsigned cursor = st->document.fieldCursor();
        ic->surroundingText().setText(st->document.fieldText(), cursor, cursor);
    }
    st->converting = reply["converting"].asBool();
    drawPreedit(ic, st);
    const Json &ui = response["ui"];
    drawPanel(ic, st, ui);
    act(ic, st, ui);
    // What the dictionary did (a word learned, the last one undone) shows in the menu.
    if (committed || ui.has("learned")) updateMenu(ic, st);
    if (response.has("notify")) runPending(response["notify"]);
    return reply["handled"].asBool();
}

void Engine::drawPreedit(fcitx::InputContext *ic, State *st) {
    fcitx::Text text;
    const std::u16string &preedit = st->document.preedit();
    if (!preedit.empty()) {
        // The word underlined, as macOS draws marked text; while converting, the clause the
        // candidates are for highlighted.
        int start = st->document.clauseStart(), length = st->document.clauseLength();
        fcitx::TextFormatFlags underline = fcitx::TextFormatFlag::Underline;
        fcitx::TextFormatFlags clause{fcitx::TextFormatFlag::Underline, fcitx::TextFormatFlag::HighLight};
        if (length > 0) {
            if (start > 0) text.append(Utf8(preedit.substr(0, static_cast<size_t>(start))), underline);
            text.append(Utf8(preedit.substr(static_cast<size_t>(start), static_cast<size_t>(length))), clause);
            if (start + length < static_cast<int>(preedit.size()))
                text.append(Utf8(preedit.substr(static_cast<size_t>(start + length))), underline);
        } else {
            text.append(Utf8(preedit), st->converting ? clause : underline);
        }
        text.setCursor(static_cast<int>(text.textLength()));
    }
    auto &panel = ic->inputPanel();
    // Apps that draw preedit get it in the text; the rest see it in fcitx5's panel.
    if (ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
        panel.setClientPreedit(text);
        panel.setPreedit(fcitx::Text());
    } else {
        panel.setClientPreedit(fcitx::Text());
        panel.setPreedit(text);
    }
    ic->updatePreedit();
}

void Engine::drawPanel(fcitx::InputContext *ic, State *st, const Json &ui) {
    auto &panel = ic->inputPanel();
    const Json &candidates = ui["candidates"];
    const Json &readings = ui["readings"];
    if (candidates.isObject()) {
        // The candidate card: nine to a page, numbered, the reading under them.
        auto list = std::make_unique<fcitx::CommonCandidateList>();
        list->setPageSize(9);
        list->setLabels({"1. ", "2. ", "3. ", "4. ", "5. ", "6. ", "7. ", "8. ", "9. "});
        list->setLayoutHint(fcitx::CandidateLayoutHint::Vertical);
        const auto &texts = candidates["texts"].items();
        for (size_t i = 0; i < texts.size(); ++i) {
            list->append<ChoiceWord>(this, static_cast<int>(i), fcitx::Text(texts[i].asString()), false);
        }
        int selected = candidates["selected"].asInt();
        if (!texts.empty()) {
            selected = std::max(0, std::min(selected, static_cast<int>(texts.size()) - 1));
            list->setPage(selected / 9);
            list->setGlobalCursorIndex(selected);
        }
        panel.setCandidateList(std::move(list));
        int pages = static_cast<int>((texts.size() + 8) / 9);
        std::string footer = candidates["reading"].asString();
        if (pages > 1) footer += "  " + std::to_string(selected / 9 + 1) + "/" + std::to_string(pages);
        panel.setAuxDown(fcitx::Text(footer));
    } else if (readings.isObject()) {
        // The switch key's strip: each reading on one line, a check after the one the dictionary
        // remembers and a pencil after the one corrected once.
        auto list = std::make_unique<fcitx::CommonCandidateList>();
        const auto &texts = readings["texts"].items();
        list->setPageSize(std::max<int>(1, static_cast<int>(texts.size())));
        list->setLabels(std::vector<std::string>(texts.size(), ""));
        list->setLayoutHint(fcitx::CandidateLayoutHint::Horizontal);
        int remembered = readings.has("remembered") ? readings["remembered"].asInt(-1) : -1;
        int once = readings.has("once") ? readings["once"].asInt(-1) : -1;
        for (size_t i = 0; i < texts.size(); ++i) {
            fcitx::Text text;
            text.append(texts[i].asString());
            std::string tag = " " + Tag(readings["tags"][i].asString());
            if (static_cast<int>(i) == remembered) tag += " ✓";
            if (static_cast<int>(i) == once) tag += " ✎";
            text.append(tag, fcitx::TextFormatFlag::DontCommit);
            list->append<ChoiceWord>(this, static_cast<int>(i), std::move(text), true);
        }
        if (!texts.empty()) list->setGlobalCursorIndex(std::max(0, readings["selected"].asInt()));
        panel.setCandidateList(std::move(list));
        panel.setAuxDown(fcitx::Text());
    } else {
        panel.setCandidateList(nullptr);
        panel.setAuxDown(fcitx::Text());
    }
    const Json &learned = ui["learned"];
    if (learned.isObject()) {
        // What a correction did, for a moment: Noted after the first, Learned once for good, Reset
        // when switching back to Araso's own reading forgot the word.
        std::string learning = learned["learning"].asString();
        const char *said = learning == "once" ? "Noted" : learning == "forGood" ? "Learned" : "Reset";
        const char *mark = learning == "once" ? "✎ " : learning == "forGood" ? "✓ " : "↺ ";
        panel.setAuxUp(fcitx::Text(mark + learned["text"].asString() + " · " + L(said)));
        auto reference = ic->watch();
        learnedTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, Now() + kLearnedShown, 0, [this, reference](fcitx::EventSourceTime *, uint64_t) {
                if (auto *ic = reference.get()) {
                    ic->inputPanel().setAuxUp(fcitx::Text());
                    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
                }
                learnedTimer_.reset();
                return true;
            });
    }
    (void)st;
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void Engine::act(fcitx::InputContext *ic, State *st, const Json &ui) {
    if (ui.has("paused")) {
        // The icon changes (macOS's can't, so Araso draws one under the caret), and fcitx5 shows
        // the input method's name with "Paused" by the caret.
        st->paused = ui["paused"].asBool();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::StatusArea);
        instance_->showInputMethodInformation(ic);
    }
    if (ui.has("trace")) {
        Json message = Json::object();
        message.set("trace", ui["trace"]);
        Send("settings", message.dump());
    }
    if (ui["settingsChanged"].asBool()) Send("settings", R"({"settingsChanged":true})");
    if (ui.has("openSettings")) {
        fcitx::startProcess({Bridge::settingsProgram(), "--settings", ui["openSettings"].asString()});
    }
}

void Engine::runPending(const Json &notify) {
    for (const Json &id : notify.items()) {
        auto found = clients_.find(id.asInt());
        if (found == clients_.end()) continue;
        auto *ic = found->second.get();
        auto *st = state(ic);
        if (!ic || !st) continue;
        answer(ic, st, request("pending", ic, st));
    }
}

void Engine::keyEvent(const fcitx::InputMethodEntry &entry, fcitx::KeyEvent &event) {
    // 한/영 came first, through the watcher above.
    if (!event.isRelease() && event.rawKey().sym() == FcitxKey_Hangul) return;
    keyEvent_(entry, event);
}

void Engine::keyEvent_(const fcitx::InputMethodEntry &, fcitx::KeyEvent &event) {
    auto *ic = event.inputContext();
    auto *st = state(ic);
    if (!attached(ic, st)) return;
    Json key = WindowsKey(event.rawKey());
    if (key.isNull()) return;
    Json extra = Json::object();
    extra.set("key", key);
    if (event.isRelease()) {
        // Only modifiers' going up matters: a tap of the switch or pause key.
        if (!IsModifier(event.rawKey())) return;
        if (answer(ic, st, request("keyUp", ic, st, extra))) event.filterAndAccept();
        return;
    }
    // A key the session doesn't take reaches the app after any edits it made (the Space after a
    // word, as macOS's app types it), so nothing is typed here for it.
    if (answer(ic, st, request("key", ic, st, extra))) event.filterAndAccept();
}

void Engine::activate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    auto *st = state(ic);
    ic->statusArea().addAction(fcitx::StatusGroup::InputMethod, &menuAction_);
    if (!attached(ic, st)) return;
    answer(ic, st, request("focus", ic, st));
    updateMenu(ic, st);
}

void Engine::deactivate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
    auto *ic = event.inputContext();
    auto *st = state(ic);
    // The field lost the focus (or another input method was picked): what was typed goes in as shown.
    if (st && st->client) answer(ic, st, request("blur", ic, st));
    if (ic) {
        ic->inputPanel().reset();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }
}

void Engine::reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
    // The app reset the field (a click elsewhere in it): the word goes in as shown, as a Mac app
    // commits the marked text, and the session starts afresh.
    auto *ic = event.inputContext();
    auto *st = state(ic);
    if (st && st->client && st->document.composing()) answer(ic, st, request("blur", ic, st));
}

std::string Engine::subModeIconImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &ic) {
    auto *st = state(&ic);
    return st && st->paused ? "araso-paused" : "";
}

std::string Engine::subModeLabelImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &ic) {
    auto *st = state(&ic);
    return st && st->paused ? L("Paused") : "";
}

// MARK: Menu

void Engine::updateMenu(fcitx::InputContext *ic, State *st) {
    if (!ic || !st || !st->client) return;
    Json request = Json::object();
    request.set("op", "menu");
    request.set("client", st->client);
    Json response = Bridge::shared().request(request);
    for (auto *action : menu_.actions()) menu_.removeAction(action);
    size_t used = 0;
    for (const Json &line : response["reply"]["menu"].items()) {
        if (used == items_.size()) {
            items_.push_back(std::make_unique<MenuItemAction>(this));
            instance_->userInterfaceManager().registerAction("araso-menu-" + std::to_string(used), items_.back().get());
        }
        auto *action = items_[used++].get();
        bool separator = line["separator"].asBool();
        action->setSeparator(separator);
        action->item = line["enabled"].asBool() ? line["id"].asString() : "";
        action->setShortText(separator ? "" : line["title"].asString());
        // A check only on what is on, as the Mac menu marks it.
        action->setCheckable(line["checked"].asBool());
        action->setChecked(line["checked"].asBool());
        menu_.addAction(action);
    }
    ic->updateUserInterface(fcitx::UserInterfaceComponent::StatusArea);
}

void Engine::menuSelect(fcitx::InputContext *ic, const std::string &item) {
    auto *st = state(ic);
    if (!attached(ic, st)) return;
    Json extra = Json::object();
    extra.set("item", item);
    answer(ic, st, request("menuSelect", ic, st, extra));
    // Pausing from the menu: the word in progress goes in (its edit is waiting for this field).
    answer(ic, st, request("pending", ic, st));
    updateMenu(ic, st);
}

void Engine::choose(fcitx::InputContext *ic, int index) {
    auto *st = state(ic);
    if (!attached(ic, st)) return;
    Json extra = Json::object();
    extra.set("index", index);
    answer(ic, st, request("choose", ic, st, extra));
}

void Engine::pick(fcitx::InputContext *ic, int index) {
    auto *st = state(ic);
    if (!attached(ic, st)) return;
    Json extra = Json::object();
    extra.set("index", index);
    answer(ic, st, request("pick", ic, st, extra));
}

// MARK: Outside requests

void Engine::listen() {
    std::string folder = Bridge::socketFolder();
    mkdir(folder.c_str(), 0700);
    std::string path = folder + "/ime";
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof address.sun_path) return;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    socket_ = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (socket_ < 0) return;
    unlink(path.c_str());
    if (bind(socket_, reinterpret_cast<sockaddr *>(&address), sizeof address) != 0) {
        ARASO_ERROR() << "can't listen on " << path << ": " << std::strerror(errno);
        close(socket_);
        socket_ = -1;
        return;
    }
    socketEvent_ = instance_->eventLoop().addIOEvent(
        socket_, fcitx::IOEventFlag::In, [this](fcitx::EventSourceIO *, int fd, fcitx::IOEventFlags) {
            char buffer[65536];
            for (;;) {
                ssize_t got = recv(fd, buffer, sizeof buffer, 0);
                if (got <= 0) break;
                external(std::string(buffer, static_cast<size_t>(got)));
            }
            return true;
        });
}

void Engine::setActiveByDefault(bool on) {
    fcitx::RawConfig raw;
    raw.setValueByPath("Behavior/ActiveByDefault", on ? "True" : "False");
    instance_->globalConfig().load(raw, true);
    if (!instance_->globalConfig().safeSave()) ARASO_ERROR() << "can't save fcitx5's config";
}

void Engine::external(const std::string &message) {
    bool ok = false;
    Json request = Json::parse(message, &ok);
    if (!ok || !request.isObject()) return;
    std::string op = request["op"].asString();
    if (op == "activeByDefault") {
        setActiveByDefault(request["on"].asBool());
        return;
    }
    // Only what the settings window and vim send; the rest is the text fields' own.
    if (op != "reload" && op != "vim") return;
    Json response = Bridge::shared().request(request);
    if (response.has("notify")) runPending(response["notify"]);
    if (op == "reload") {
        if (auto *ic = instance_->mostRecentInputContext()) updateMenu(ic, state(ic));
    }
}

void Engine::scheduleUpdateCheck(uint64_t delay) {
    updateTimer_ = instance_->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, Now() + delay, 0, [this](fcitx::EventSourceTime *, uint64_t) {
            if (access(Bridge::settingsProgram().c_str(), X_OK) == 0) {
                fcitx::startProcess({Bridge::settingsProgram(), "--check-update"});
            }
            scheduleUpdateCheck(kCheckEvery);
            return true;
        });
}

}  // namespace araso

FCITX_ADDON_FACTORY(araso::EngineFactory);
