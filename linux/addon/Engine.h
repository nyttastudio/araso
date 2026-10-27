// Araso as a fcitx5 input method (docs/linux-port.md): what IMKInputController is on macOS and
// ArasoTip.dll with ArasoHost.exe are on Windows. fcitx5 runs one daemon per user and loads this
// addon into it, so the Swift runtime (libArasoBridge.so) lives here too, on fcitx5's main thread,
// and serves every app as Araso's one process does on macOS.
#pragma once

#include "Bridge.h"
#include "Document.h"

#include <fcitx-utils/event.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx/action.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>
#include <fcitx/menu.h>

#include <map>
#include <memory>
#include <string>
#include <vector>

namespace araso {

class Engine;

/// One input context's state: an app's text field (a window's, for apps that share one).
struct State : public fcitx::InputContextProperty {
    /// The session's client id (`attach`); 0 until attached.
    int client = 0;
    Document document;
    bool converting = false;
    bool paused = false;
};

/// A line of the input method's menu (the status area's Araso menu): ServiceRuntime's `menu`.
class MenuItemAction : public fcitx::SimpleAction {
public:
    explicit MenuItemAction(Engine *engine) : engine_(engine) {}
    std::string item;
    void activate(fcitx::InputContext *ic) override;

private:
    Engine *engine_;
};

class Engine : public fcitx::InputMethodEngineV2 {
public:
    explicit Engine(fcitx::Instance *instance);
    ~Engine() override;

    void keyEvent(const fcitx::InputMethodEntry &entry, fcitx::KeyEvent &event) override;
    void activate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
    void deactivate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
    void reset(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
    std::string subModeIconImpl(const fcitx::InputMethodEntry &entry, fcitx::InputContext &ic) override;
    std::string subModeLabelImpl(const fcitx::InputMethodEntry &entry, fcitx::InputContext &ic) override;

    /// A menu item was chosen; a candidate was clicked in the card; a reading in the strip.
    void menuSelect(fcitx::InputContext *ic, const std::string &item);
    void choose(fcitx::InputContext *ic, int index);
    void pick(fcitx::InputContext *ic, int index);

    /// A request from outside (`ime` socket: the settings window's `reload` and
    /// `activeByDefault`, vim's mode).
    void external(const std::string &message);

private:
    /// A key for this input context (`keyEvent`, and 한/영 ahead of fcitx5's own keys).
    void keyEvent_(const fcitx::InputMethodEntry &entry, fcitx::KeyEvent &event);
    State *state(fcitx::InputContext *ic);
    bool attached(fcitx::InputContext *ic, State *state);
    std::string app(fcitx::InputContext *ic) const;
    /// `op` for this input context, with a fresh snapshot of its field.
    Json request(const char *op, fcitx::InputContext *ic, State *state, Json extra = Json::object());
    /// Makes the answer's edits in the app, draws its UI, and makes what other clients have waiting.
    /// Whether the key was taken.
    bool answer(fcitx::InputContext *ic, State *state, const Json &response);
    void drawPreedit(fcitx::InputContext *ic, State *state);
    void drawPanel(fcitx::InputContext *ic, State *state, const Json &ui);
    void act(fcitx::InputContext *ic, State *state, const Json &ui);
    void updateMenu(fcitx::InputContext *ic, State *state);
    void runPending(const Json &notify);
    void listen();
    void scheduleUpdateCheck(uint64_t delay);
    /// fcitx5's Active By Default: a new field starts in Araso, not in the keyboard layout.
    void setActiveByDefault(bool on);

    fcitx::Instance *instance_;
    fcitx::FactoryFor<State> factory_;
    bool ready_ = false;
    std::map<int, fcitx::TrackableObjectReference<fcitx::InputContext>> clients_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>> watchers_;

    fcitx::SimpleAction menuAction_;
    fcitx::Menu menu_;
    std::vector<std::unique_ptr<MenuItemAction>> items_;

    int socket_ = -1;
    std::unique_ptr<fcitx::EventSourceIO> socketEvent_;
    std::unique_ptr<fcitx::EventSourceTime> learnedTimer_, updateTimer_;
    std::unique_ptr<fcitx::EventSource> warmUp_;
};

class EngineFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override { return new Engine(manager->instance()); }
};

}  // namespace araso
