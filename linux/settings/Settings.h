// The settings window (araso-settings --settings <tab>), Qt 6 Widgets: the Windows one's panes
// (windows/host/Settings*.cpp) and SettingsWindow.swift's on macOS. It edits the files through its
// own bridge (no kanji converter), then tells the addon to read them again (the `ime` socket).
// Each pane is laid out top to bottom and built afresh after every change, as on Windows.
#pragma once

#include "Bridge.h"
#include "Json.h"

#include <QBoxLayout>
#include <QString>

#include <functional>
#include <string>
#include <vector>

class QCheckBox;
class QComboBox;
class QPushButton;
class QTreeWidget;
class QWidget;
class QPlainTextEdit;

namespace araso {
namespace settings {

struct State {
    QWidget *window = nullptr;
    QWidget *content = nullptr;
    QVBoxLayout *layout = nullptr;
    int pane = 0;
    Json model;

    // Apps
    std::string selectedApp;
    // Dictionary
    int filter = 0;
    QString search;
    QTreeWidget *wordList = nullptr;
    std::vector<Json> shownWords;
    // Try Typing
    std::vector<Json> traces;
    QTreeWidget *traceList = nullptr;
    QString typed;
    // About
    QString updateStatus;
    bool busy = false;
};

extern State g;

/// The switch keys, in settings.json's order, with their names and notes on Linux.
struct SwitchKeyInfo {
    const char *id;
    const char *name;
    const char *note;
};
extern const SwitchKeyInfo kSwitchKeys[5];

QString Q(const std::string &text);
QString T(const char *english);
QString T(const char *english, std::initializer_list<std::string> arguments);

Json Request(Json request);
void LoadModel();
void Rebuild();
void ShowPane(int pane);
int PaneIndex(const std::string &id);
/// Writes a change through the bridge, then the addon and this window catch up.
void Apply(Json change, bool kanjiReset = false);
void ChangeSettings(const std::function<void(Json &)> &edit);
void ChangeDefault(const std::function<void(Json &)> &edit);
Json AppEntry(const std::string &app);
void ChangeApp(const std::string &app, const std::function<void(Json &)> &edit);
bool HasKey(const Json &keys, const std::string &id);
Json WithKey(const Json &keys, const std::string &id, bool on);
QString KeyNames(const Json &keys);
/// Tells the addon the files changed (`kanjiReset`: it reset the kanji order too).
void TellInputMethod(bool kanjiReset = false);

// Layout: each adds to the pane's column (or to `row` when given).
void Title(const QString &text, const QString &note);
void Heading(const QString &text);
void Note(const QString &text, int indent = 0);
QCheckBox *Check(const QString &text, bool on, bool enabled, std::function<void(bool)> changed, int indent = 0);
QComboBox *Combo(const QString &label, const QStringList &items, int selected, bool enabled,
                 std::function<void(int)> changed, int indent = 0);
QHBoxLayout *Line();
QPushButton *Push(const QString &text, std::function<void()> clicked, bool enabled = true, QBoxLayout *row = nullptr);
QTreeWidget *List(const QStringList &columns, const std::vector<int> &widths, int height);
void Row(QTreeWidget *list, const QStringList &cells);
int Selected(QTreeWidget *list);
bool Confirm(const QString &question, const QString &detail);

// The panes.
void BuildLanguages();
void BuildKeys();
void BuildApps();
void BuildDictionary();
void BuildTyping();
void BuildAbout();
/// A trace from the addon (Try Typing).
void AddTrace(const Json &trace);
/// GitHub's latest release, asked in the background (About).
void CheckForUpdates();
/// The dictionary's add/edit window, with `keys` filled in (Try Typing's Add to Dictionary).
void EditWord(const Json *word, const std::string &keys);

}  // namespace settings

/// The settings window; `--check-update` (the addon's daily check) without a window.
int RunSettings(const std::string &tab);
int CheckUpdateQuietly();

}  // namespace araso
