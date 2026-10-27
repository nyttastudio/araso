// The Languages, Keys and Apps panes (windows/host/SettingsPanes.cpp; SettingsWindow.swift on macOS).
#include "Settings.h"

#include "Keys.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDir>
#include <QFile>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QPushButton>
#include <QTreeWidget>
#include <QVBoxLayout>

#include <unistd.h>

#include <algorithm>
#include <set>

namespace araso {
namespace settings {

namespace {

const char *kLatinLayouts[] = {"qwerty", "colemak", "colemakDH"};
const char *kLatinNames[] = {"QWERTY", "Colemak", "Colemak-DH"};

int LatinIndex(const std::string &layout) {
    for (int k = 0; k < 3; k++) if (layout == kLatinLayouts[k]) return k;
    return 0;
}

const char *kKoreanLayouts[] = {"dubeolsik", "sebeolsikFinal", "sebeolsik390"};

int KoreanIndex(const std::string &layout) {
    for (int k = 0; k < 3; k++) if (layout == kKoreanLayouts[k]) return k;
    return 0;
}

double Strict() { return g.model["strictThreshold"].asNumber(0.97); }

/// fcitx5's Active By Default, from its config file: fcitx5 saves it there when Araso changes it.
bool ActiveByDefault() {
    QString config = qEnvironmentVariable("XDG_CONFIG_HOME");
    if (config.isEmpty()) config = QDir::homePath() + "/.config";
    QFile file(config + "/fcitx5/config");
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
    bool behavior = false;
    while (!file.atEnd()) {
        QString line = QString::fromUtf8(file.readLine()).trimmed();
        if (line.startsWith('[')) behavior = line == "[Behavior]";
        else if (behavior && line.startsWith("ActiveByDefault=")) return line.mid(16) == "True";
    }
    return false;
}

/// A label that takes the keys pressed in it, before any input method sees them: the pause
/// shortcut's recorder.
class KeyField : public QLabel {
public:
    std::function<void(QKeyEvent *)> pressed;
    KeyField() {
        setFocusPolicy(Qt::StrongFocus);
        setAttribute(Qt::WA_InputMethodEnabled, false);
        setAlignment(Qt::AlignCenter);
        setFrameShape(QFrame::StyledPanel);
        setMinimumHeight(48);
        QFont font = this->font();
        font.setBold(true);
        setFont(font);
    }

protected:
    void keyPressEvent(QKeyEvent *event) override {
        if (pressed) pressed(event);
    }
};

}  // namespace

// MARK: - Languages

void BuildLanguages() {
    const Json &settings = g.model["settings"];
    const Json &policy = g.model["defaultPolicy"];
    bool japanese = settings["japanese"].asBool();

    Heading(T("Languages"));
    // Not a setting of Araso's: fcitx5's, which the input method changes (the window may not write
    // fcitx5's file while it runs). The box keeps what was clicked until fcitx5 has saved it.
    Check(T("On in every text field"), ActiveByDefault(), true, [](bool on) {
        Json request = Json::object();
        request.set("op", "activeByDefault");
        request.set("on", on);
        Send("ime", request.dump());
    });
    Note(T("Off: a text field starts in the keyboard layout, and Ctrl+Space turns Araso on there (fcitx5's Active By Default)."), 20);
    Check(T("Convert words"), policy["enabled"].asBool(true), true, [](bool on) {
        ChangeDefault([on](Json &p) { p.set("enabled", on); });
    });
    Note(T("Off: keys go to the app as typed, as with the ABC layout. Apps can differ, under Apps."), 20);
    auto *always = new QLabel(T("Korean · English") + "   —   " + T("Always on"));
    always->setContentsMargins(20, 0, 0, 0);
    g.layout->addWidget(always);
    Check(T("Japanese"), japanese, true, [](bool on) { ChangeSettings([on](Json &s) { s.set("japanese", on); }); });
    Note(T("Type Japanese with romaji; Space converts to kanji."), 20);

    Heading(T("Layouts"));
    Combo(T("Hangul"), {T("2-set"), T("3-set final"), T("3-set 390")}, KoreanIndex(settings["koreanLayout"].asString()),
          true, [](int index) {
              ChangeSettings([index](Json &s) { s.set("koreanLayout", kKoreanLayouts[std::max(0, index)]); });
          });
    Note(T("3-set types jamo on the digit and symbol keys too; a number on its own stays a number."), 160);
    int latin = LatinIndex(settings["latinLayout"].asString());
    Combo(T("English letters"), {kLatinNames[0], kLatinNames[1], kLatinNames[2]}, latin, true, [](int index) {
        ChangeSettings([index](Json &s) { s.set("latinLayout", kLatinLayouts[std::max(0, index)]); });
    });
    const Json &romaji = settings["japaneseLayout"];
    int romajiIndex = romaji.isString() ? LatinIndex(romaji.asString()) + 1 : 0;
    Combo(T("Romaji"), {T("Same as English (%@)", {kLatinNames[latin]}), kLatinNames[0], kLatinNames[1], kLatinNames[2]},
          romajiIndex, japanese, [](int index) {
              ChangeSettings([index](Json &s) {
                  if (index <= 0) s.remove("japaneseLayout");
                  else s.set("japaneseLayout", kLatinLayouts[index - 1]);
              });
          });
    Note(T("Used with Japanese on."), 160);

    Heading(T("Japanese input"));
    Check(T("Live conversion"), settings["liveConversion"].asBool(), japanese,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("liveConversion", on); }); });
    Note(T("Shows the top kanji candidate as you type."), 20);
    Check(T("Full-width numbers"), settings["fullWidthDigits"].asBool(), japanese,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("fullWidthDigits", on); }); });
    Note(T("１２３ after Japanese; Space offers 123."), 20);
    Check(T("Full-width space"), settings["fullWidthSpace"].asBool(), japanese,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("fullWidthSpace", on); }); });
    Note(T("A full-width space after Japanese; Shift+Space types the other width."), 20);
    auto *row = Line();
    row->addWidget(new QLabel(T("Kanji candidate order")));
    Push(T("Reset…"), [] {
        if (!Confirm(T("Reset the kanji candidate order?"),
                     T("Kanji you picked before won't come first anymore. Remembered words stay."))) return;
        Json change = Json::object();
        change.set("resetKanji", true);
        Apply(change, true);
    }, japanese, row);
    row->addStretch(1);
    Note(T("Kanji you pick come first next time."));
}

// MARK: - Keys

void BuildKeys() {
    const Json &settings = g.model["settings"];
    const Json &policy = g.model["defaultPolicy"];
    const Json &keys = policy["switchKeys"];
    const Json &pause = settings["pauseKey"];
    // The switch key the pause key takes, if any: the two are never chosen together.
    std::string taken;
    if (pause.isString()) {
        if (pause.asString() == "rightOption") taken = "rightOption";
        if (pause.asString() == "rightShift") taken = "rightShift";
    } else if (pause.isObject() && pause["keyCode"].asInt() == 49 && pause["modifiers"].size() == 1 &&
               pause["modifiers"][0].asString() == "option") {
        taken = "optionSpace";
    }

    Heading(T("Switch a word's language"));
    Note(T("Turns the word being typed, or the one just typed, into the next reading. Choose one or more."));
    for (const auto &info : kSwitchKeys) {
        std::string id = info.id;
        Check(T(info.name), HasKey(keys, id), taken != id, [id](bool on) {
            ChangeDefault([id, on](Json &p) { p.set("switchKeys", WithKey(p["switchKeys"], id, on)); });
        });
        Note(taken == id ? T("This key pauses. Choose another pause key first.") : T(info.note), 20);
    }
    QString names = KeyNames(keys);
    if (names.isEmpty()) Note(T("Nothing switches a word's language."));
    else if (keys.size() == 5) Note(T("All of these switch languages."));
    else Note(T("Switching: %@. The others go to the app as usual.", {names.toStdString()}));
    Note(T("A right Alt or Shift tap with other modifiers is left to what it's bound to."));

    Heading(T("Apps with their own keys"));
    int own = 0;
    for (const Json &app : g.model["apps"].items()) if (app["entry"]["switchKeys"].isArray()) own++;
    Note(own == 0 ? T("Every app uses these keys.") : own == 1 ? T("One app uses its own keys.")
                                                              : T("%ld apps use their own keys.", {std::to_string(own)}));
    Push(T("Set in Apps…"), [] { ShowPane(PaneIndex("apps")); });

    Heading(T("Other keys"));
    Check(T("Return only confirms"), settings["returnConfirmsOnly"].asBool(true), true,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("returnConfirmsOnly", on); }); });
    Note(T("Return on an underlined word confirms it; press it again for a new line. Japanese is always only confirmed."), 20);

    Heading(T("Pause"));
    // Off, the right-hand taps (Ctrl plays ⌘'s part, Super ⌃'s), and a recorded shortcut.
    QStringList items = {T("Off"), T("Right Ctrl tap (한자 on Korean keyboards)"), T("Right Alt tap"), T("Right Shift tap"),
                         T("Right Super tap")};
    const char *taps[] = {"off", "rightCommand", "rightOption", "rightShift", "rightControl"};
    for (int k = 2; k <= 3; k++) {
        if (HasKey(keys, taps[k])) items[k] = T("%@ — switches languages", {items[k].toStdString()});
    }
    int selected = 0;
    if (pause.isString()) {
        for (int k = 0; k < 5; k++) if (pause.asString() == taps[k]) selected = k;
    } else if (pause.isObject()) {
        QString name;
        for (const Json &modifier : pause["modifiers"].items()) {
            std::string m = modifier.asString();
            name += m == "command" ? "Ctrl+" : m == "option" ? "Alt+" : m == "shift" ? "Shift+" : "Super+";
        }
        items << name + Q(pause["key"].asString());
        selected = items.size() - 1;
    }
    Combo(T("Pause"), items, selected, true, [taps, selected](int index) {
        if (index < 0 || index > 4 || index == selected) return;
        std::string tap = taps[index];
        ChangeSettings([tap](Json &s) { s.set("pauseKey", tap); });
    });
    Push(T("Record Shortcut…"), [] {
        QDialog dialog(g.window);
        dialog.setWindowTitle(T("Type a shortcut"));
        auto *column = new QVBoxLayout(&dialog);
        auto *field = new KeyField;
        field->setText(T("Type a shortcut"));
        auto *hint = new QLabel(T("Add Ctrl, Alt or Super: without one the key types. F-keys can go alone.") + " " +
                                T("Press Esc to cancel."));
        hint->setWordWrap(true);
        column->addWidget(field);
        column->addWidget(hint);
        Json chosen;
        field->pressed = [&](QKeyEvent *event) {
            int key = event->key();
            if (key == Qt::Key_Shift || key == Qt::Key_Control || key == Qt::Key_Alt || key == Qt::Key_Meta ||
                key == Qt::Key_Super_L || key == Qt::Key_Super_R || key == Qt::Key_AltGr) return;
            auto modifiers = event->modifiers();
            if (key == Qt::Key_Escape && !(modifiers & (Qt::ShiftModifier | Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier))) {
                dialog.reject();
                return;
            }
            // The key as the addon would see it: its keycode and keysym, the modifiers held.
            fcitx::KeyStates states;
            if (modifiers & Qt::ShiftModifier) states |= fcitx::KeyState::Shift;
            if (modifiers & Qt::ControlModifier) states |= fcitx::KeyState::Ctrl;
            if (modifiers & Qt::AltModifier) states |= fcitx::KeyState::Alt;
            if (modifiers & Qt::MetaModifier) states |= fcitx::KeyState::Super;
            fcitx::Key pressed(static_cast<fcitx::KeySym>(event->nativeVirtualKey()), states,
                               static_cast<int>(event->nativeScanCode()));
            Json request = Json::object();
            request.set("op", "shortcut");
            request.set("key", WindowsKey(pressed));
            Json answer = Request(request);
            QString name = Q(answer["shortcutName"].asString());
            std::string problem = answer["problem"].asString();
            field->setText(name);
            if (!answer["shortcut"].isObject()) return;
            if (problem == "types") {
                hint->setText(T("Add Ctrl, Alt or Super: without one the key types. F-keys can go alone."));
            } else if (problem == "arasos") {
                hint->setText(T("%@ types hiragana or katakana.", {name.toStdString()}));
            } else if (problem == "switchKey") {
                hint->setText(T("%@ switches a word's language. Turn that off first.", {name.toStdString()}));
            } else {
                chosen = answer["shortcut"];
                dialog.accept();
            }
        };
        field->setFocus();
        dialog.resize(380, 160);
        if (dialog.exec() == QDialog::Accepted && chosen.isObject()) {
            ChangeSettings([chosen](Json &s) { s.set("pauseKey", chosen); });
        }
    });
    Note(T("Keys go through as typed in that text field, for hjkl in terminal programs. Press it again to resume."));
}

// MARK: - Apps

namespace {

/// A per-app value as the list shows it: the entry's own, or the default's after "Default ·".
QString Value(const Json &entry, const char *key, const QString &own, const QString &fallback) {
    return entry[key].isNull() ? T("Default · %@", {fallback.toStdString()}) : own;
}

QString OnOff(bool on) { return on ? T("On") : T("Off"); }

/// This user's running programs, by the name fcitx5 knows them by.
QStringList RunningApps() {
    std::set<QString> names;
    uid_t me = getuid();
    for (const QString &pid : QDir("/proc").entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        bool number = false;
        pid.toInt(&number);
        if (!number) continue;
        QFileInfo info("/proc/" + pid);
        if (info.ownerId() != me) continue;
        QFile comm("/proc/" + pid + "/comm");
        if (!comm.open(QIODevice::ReadOnly)) continue;
        QString name = QString::fromUtf8(comm.readAll()).trimmed().toLower();
        if (!name.isEmpty()) names.insert(name);
    }
    return QStringList(names.begin(), names.end());
}

void AddApp() {
    QDialog dialog(g.window);
    dialog.setWindowTitle(T("Add App…"));
    auto *column = new QVBoxLayout(&dialog);
    auto *about = new QLabel(T("Add an app by its program name, such as firefox or org.gnome.TextEditor."));
    about->setWordWrap(true);
    column->addWidget(about);
    column->addWidget(new QLabel(T("Program name")));
    auto *name = new QLineEdit;
    name->setAttribute(Qt::WA_InputMethodEnabled, false);
    column->addWidget(name);
    column->addWidget(new QLabel(T("Running apps")));
    auto *list = new QListWidget;
    list->addItems(RunningApps());
    QObject::connect(list, &QListWidget::currentTextChanged, name, &QLineEdit::setText);
    column->addWidget(list);
    auto *buttons = new QDialogButtonBox;
    buttons->addButton(T("Cancel"), QDialogButtonBox::RejectRole);
    buttons->addButton(T("Add"), QDialogButtonBox::AcceptRole)->setDefault(true);
    QObject::connect(buttons, &QDialogButtonBox::accepted, &dialog, &QDialog::accept);
    QObject::connect(buttons, &QDialogButtonBox::rejected, &dialog, &QDialog::reject);
    column->addWidget(buttons);
    name->setFocus();
    dialog.resize(400, 380);
    if (dialog.exec() != QDialog::Accepted) return;
    std::string app = name->text().trimmed().toLower().toStdString();
    if (app.empty()) return;
    g.selectedApp = app;
    Json change = Json::object();
    change.set("app", app);
    change.set("entry", Json::object());
    Apply(change);
}

}  // namespace

void BuildApps() {
    const Json &policy = g.model["defaultPolicy"];
    bool strict = policy["conversionThreshold"].asNumber(0.5) >= Strict();
    Heading(T("Default — every app"));
    if (!policy["enabled"].asBool(true)) Note(T("Convert words is off under Languages, so nothing converts."));
    Combo(T("Conversion"), {T("Normal"), T("Strict")}, strict ? 1 : 0, true, [](int index) {
        ChangeDefault([index](Json &p) { p.set("conversionThreshold", index == 1 ? Strict() : 0.5); });
    });
    Note(strict ? T("Converts only words that are clearly Korean or Japanese, so short commands stay as typed (gst stays gst). For terminals.")
                : T("Converts a word when it reads more like Korean or Japanese than English (gst → ㅎㄴㅅ)."));

    Heading(T("Exceptions — only apps that differ"));
    const Json &apps = g.model["apps"];
    if (apps.size() == 0) Note(T("None. Add an app that should work differently."));
    QTreeWidget *list = List({T("App"), T("Convert words"), T("Conversion"), T("Switch keys"), T("After Space / punctuation")},
                             {150, 110, 110, 150, 130}, 150);
    QString defaultConversion = strict ? T("Strict") : T("Normal");
    int selectedRow = -1;
    std::vector<std::string> names;
    for (const Json &item : apps.items()) {
        const Json &entry = item["entry"];
        const Json &own = item["policy"];
        std::string app = item["app"].asString();
        QString keys = KeyNames(own["switchKeys"]);
        Row(list, {Q(app), Value(entry, "enabled", OnOff(own["enabled"].asBool(true)), OnOff(policy["enabled"].asBool(true))),
                   Value(entry, "conversionThreshold", own["conversionThreshold"].asNumber() >= Strict() ? T("Strict") : T("Normal"), defaultConversion),
                   Value(entry, "switchKeys", keys.isEmpty() ? T("None — can't switch") : keys, KeyNames(policy["switchKeys"])),
                   Value(entry, "holdSpace", own["holdSpace"].asBool() ? T("Hold") : T("Finish"), T("Finish"))});
        if (app == g.selectedApp) selectedRow = static_cast<int>(names.size());
        names.push_back(app);
    }
    if (selectedRow < 0 && !names.empty()) {
        selectedRow = 0;
        g.selectedApp = names[0];
    }
    if (selectedRow >= 0) list->setCurrentItem(list->topLevelItem(selectedRow));
    QObject::connect(list, &QTreeWidget::currentItemChanged, list, [list, names](QTreeWidgetItem *item, QTreeWidgetItem *) {
        int row = item ? list->indexOfTopLevelItem(item) : -1;
        if (row < 0 || row >= static_cast<int>(names.size()) || g.selectedApp == names[static_cast<size_t>(row)]) return;
        g.selectedApp = names[static_cast<size_t>(row)];
        Rebuild();
    });
    auto *row = Line();
    Push(T("Add App…"), AddApp, true, row);
    Push(T("Remove"), [] {
        if (g.selectedApp.empty()) return;
        Json change = Json::object();
        change.set("removeApp", g.selectedApp);
        g.selectedApp.clear();
        Apply(change);
    }, !g.selectedApp.empty(), row);
    row->addStretch(1);
    if (g.selectedApp.empty()) return;

    // The selected app: each value its own or the default's.
    std::string app = g.selectedApp;
    Json entry = AppEntry(app);
    Heading(Q(app));
    Note(T("Grey values follow the default; anything else applies to this app only."));
    auto tri = [&](const char *key, const QString &label, const QString &fallback, const QString &on, const QString &off,
                   Json onValue, Json offValue) {
        const Json &value = entry[key];
        int selected = value.isNull() ? 0 : (value.dump() == onValue.dump() ? 1 : 2);
        if (std::string(key) == "conversionThreshold" && !value.isNull()) selected = value.asNumber() >= Strict() ? 1 : 2;
        std::string name = key;
        Combo(label, {T("Default (%@)", {fallback.toStdString()}), on, off}, selected, true,
              [app, name, onValue, offValue](int index) {
                  ChangeApp(app, [&](Json &e) {
                      if (index <= 0) e.remove(name);
                      else e.set(name, index == 1 ? onValue : offValue);
                  });
              }, 20);
    };
    tri("enabled", T("Convert words"), OnOff(policy["enabled"].asBool(true)), T("On"), T("Off"), Json(true), Json(false));
    tri("conversionThreshold", T("Conversion"), defaultConversion, T("Strict"), T("Normal"), Json(Strict()), Json(0.5));
    tri("holdSpace", T("After Space / punctuation"), T("Finish"), T("Hold"), T("Finish"), Json(true), Json(false));
    tri("fullWidth", T("Full-width"), T("On"), T("On"), T("Off"), Json(true), Json(false));
    Note(T("Hold: Space or punctuation goes inside the underline, so the word can still be changed until the next word starts. For terminals."), 20);

    const Json &own = entry["switchKeys"];
    bool custom = own.isArray();
    Combo(T("Switch keys"), {T("Default (%@)", {KeyNames(policy["switchKeys"]).toStdString()}), T("Custom")}, custom ? 1 : 0,
          true, [app](int index) {
              ChangeApp(app, [index](Json &e) {
                  if (index == 0) e.remove("switchKeys");
                  else e.set("switchKeys", g.model["defaultPolicy"]["switchKeys"]);
              });
          }, 20);
    if (custom) {
        for (const auto &info : kSwitchKeys) {
            std::string id = info.id;
            Check(T(info.name), HasKey(own, id), true, [app, id](bool on) {
                ChangeApp(app, [id, on](Json &e) { e.set("switchKeys", WithKey(e["switchKeys"], id, on)); });
            }, 180);
        }
    }
}

}  // namespace settings
}  // namespace araso
