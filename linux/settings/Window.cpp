#include "Settings.h"

#include <QApplication>
#include <QCheckBox>
#include <QComboBox>
#include <QFont>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QIcon>
#include <QLabel>
#include <QListWidget>
#include <QMessageBox>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QSocketNotifier>
#include <QSplitter>
#include <QTimer>
#include <QTreeWidget>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>

namespace araso {
namespace settings {

State g;

const SwitchKeyInfo kSwitchKeys[5] = {
    {"rightOption", "Right Alt tap", "Tap the right Alt (한/영 on Korean keyboards) on its own. Apps don't react to it."},
    {"optionSpace", "Alt+Space", "Alt and Space together. It no longer opens the window menu."},
    {"rightShift", "Right Shift tap", "Tap the right Shift on its own. Apps ignore it, so nothing else happens."},
    {"escape", "Esc", "Quick, but some apps also see the Esc and may close a dialog or clear the input."},
    {"shiftEscape", "Shift+Esc", "With nothing to change, it does nothing."},
};

namespace {

struct PaneInfo {
    const char *id;
    const char *title;
    const char *note;
    void (*build)();
};

const PaneInfo kPanes[] = {
    {"general", "Languages", "Which languages each word is decided between, the layouts they are typed on, and how Japanese types.", BuildLanguages},
    {"keys", "Keys", "The keys that change a word's language, and a few more.", BuildKeys},
    {"apps", "Apps", "How sure a word must be to convert, and apps that work differently.", BuildApps},
    {"learning", "Dictionary", "Keys that always come out one way.", BuildDictionary},
    {"typing", "Try Typing", "Type here to see how each word is decided.", BuildTyping},
    {"about", "About", "Version, updates and files.", BuildAbout},
};
constexpr int kPaneCount = sizeof kPanes / sizeof kPanes[0];

QListWidget *sidebar = nullptr;
QScrollArea *scroll = nullptr;
bool rebuildQueued = false;

/// Lays the pane out afresh: every control goes, and the pane builds its own again.
void BuildPane() {
    rebuildQueued = false;
    int position = scroll->verticalScrollBar() ? scroll->verticalScrollBar()->value() : 0;
    g.wordList = nullptr;
    g.traceList = nullptr;
    auto *content = new QWidget;
    g.content = content;
    g.layout = new QVBoxLayout(content);
    g.layout->setContentsMargins(24, 20, 24, 24);
    g.layout->setSpacing(6);
    const PaneInfo &pane = kPanes[g.pane];
    Title(T(pane.title), T(pane.note));
    pane.build();
    g.layout->addStretch(1);
    scroll->setWidget(content);  // the old pane goes with it
    scroll->verticalScrollBar()->setValue(position);
}

/// The window's socket: the addon's notices (files changed, a trace) and another copy's "show".
void Listen(QObject *owner) {
    std::string folder = Bridge::socketFolder();
    mkdir(folder.c_str(), 0700);
    std::string path = folder + "/settings";
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof address.sun_path) return;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0) return;
    unlink(path.c_str());
    if (bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof address) != 0) {
        close(fd);
        return;
    }
    auto *notifier = new QSocketNotifier(fd, QSocketNotifier::Read, owner);
    QObject::connect(notifier, &QSocketNotifier::activated, owner, [fd] {
        char buffer[65536];
        for (;;) {
            ssize_t got = recv(fd, buffer, sizeof buffer, 0);
            if (got <= 0) break;
            Json message = Json::parse(std::string(buffer, static_cast<size_t>(got)));
            if (message.has("trace")) {
                AddTrace(message["trace"]);
            } else if (message["settingsChanged"].asBool()) {
                // The input menu changed the files.
                LoadModel();
                if (g.pane != PaneIndex("typing")) Rebuild();
            } else if (message.has("show")) {
                ShowPane(PaneIndex(message["show"].asString()));
                g.window->showNormal();
                g.window->raise();
                g.window->activateWindow();
            }
        }
    });
    QObject::connect(qApp, &QCoreApplication::aboutToQuit, [path] { unlink(path.c_str()); });
}

}  // namespace

QString Q(const std::string &text) { return QString::fromStdString(text); }
QString T(const char *english) { return Q(L(english)); }
QString T(const char *english, std::initializer_list<std::string> arguments) { return Q(L(english, arguments)); }

int PaneIndex(const std::string &id) {
    for (int k = 0; k < kPaneCount; k++) if (id == kPanes[k].id) return k;
    return 0;
}

Json Request(Json request) { return Bridge::shared().request(request); }

void LoadModel() {
    Json request = Json::object();
    request.set("op", "settings");
    Json model = Request(request)["settings"];
    if (model.isObject()) g.model = model;
}

/// Not while a dialog runs its own event loop: the control that opened it is still on the stack, and
/// would go with the pane.
void BuildPaneWhenFree() {
    if (QApplication::activeModalWidget()) {
        QTimer::singleShot(50, BuildPaneWhenFree);
        return;
    }
    BuildPane();
}

void Rebuild() {
    // After the signal that asked for it: the control that sent it goes with the pane.
    if (rebuildQueued) return;
    rebuildQueued = true;
    QTimer::singleShot(0, BuildPaneWhenFree);
}

void ShowPane(int pane) {
    g.pane = std::max(0, std::min(pane, kPaneCount - 1));
    if (sidebar->currentRow() != g.pane) sidebar->setCurrentRow(g.pane);
    Rebuild();
}

void TellInputMethod(bool kanjiReset) {
    Json request = Json::object();
    request.set("op", "reload");
    if (kanjiReset) request.set("kanjiReset", true);
    Send("ime", request.dump());
}

void Apply(Json change, bool kanjiReset) {
    Json request = Json::object();
    request.set("op", "change");
    request.set("change", change);
    Json response = Request(request);
    if (response["settings"].isObject()) g.model = response["settings"];
    TellInputMethod(kanjiReset);
    Rebuild();
}

void ChangeSettings(const std::function<void(Json &)> &edit) {
    Json settings = g.model["settings"];
    edit(settings);
    Json change = Json::object();
    change.set("settings", settings);
    Apply(change);
}

void ChangeDefault(const std::function<void(Json &)> &edit) {
    Json policy = g.model["defaultPolicy"];
    edit(policy);
    Json change = Json::object();
    change.set("defaultPolicy", policy);
    Apply(change);
}

Json AppEntry(const std::string &app) {
    for (const Json &item : g.model["apps"].items()) {
        if (item["app"].asString() == app && item["entry"].isObject()) return item["entry"];
    }
    return Json::object();
}

void ChangeApp(const std::string &app, const std::function<void(Json &)> &edit) {
    Json entry = AppEntry(app);
    edit(entry);
    Json change = Json::object();
    change.set("app", app);
    change.set("entry", entry);
    Apply(change);
}

bool HasKey(const Json &keys, const std::string &id) {
    for (const Json &key : keys.items()) if (key.asString() == id) return true;
    return false;
}

Json WithKey(const Json &keys, const std::string &id, bool on) {
    Json out = Json::array();
    for (const auto &info : kSwitchKeys) {
        bool has = id == info.id ? on : HasKey(keys, info.id);
        if (has) out.push(info.id);
    }
    return out;
}

QString KeyNames(const Json &keys) {
    QStringList names;
    for (const auto &info : kSwitchKeys) {
        if (HasKey(keys, info.id)) names << T(info.name);
    }
    return names.join(", ");
}

// MARK: - Layout

static QWidget *Indented(QWidget *widget, int indent) {
    if (!indent) return widget;
    auto *holder = new QWidget;
    auto *row = new QHBoxLayout(holder);
    row->setContentsMargins(indent, 0, 0, 0);
    row->addWidget(widget, 1);
    return holder;
}

void Title(const QString &text, const QString &note) {
    auto *title = new QLabel(text);
    QFont font = title->font();
    font.setPointSizeF(font.pointSizeF() * 1.5);
    font.setBold(true);
    title->setFont(font);
    g.layout->addWidget(title);
    auto *line = new QLabel(note);
    line->setWordWrap(true);
    line->setForegroundRole(QPalette::PlaceholderText);
    g.layout->addWidget(line);
    g.layout->addSpacing(10);
}

void Heading(const QString &text) {
    g.layout->addSpacing(8);
    auto *label = new QLabel(text);
    QFont font = label->font();
    font.setBold(true);
    label->setFont(font);
    g.layout->addWidget(label);
}

void Note(const QString &text, int indent) {
    auto *label = new QLabel(text);
    label->setWordWrap(true);
    label->setTextInteractionFlags(Qt::TextSelectableByMouse);
    QFont font = label->font();
    font.setPointSizeF(font.pointSizeF() * 0.92);
    label->setFont(font);
    label->setForegroundRole(QPalette::PlaceholderText);
    g.layout->addWidget(Indented(label, indent));
}

QCheckBox *Check(const QString &text, bool on, bool enabled, std::function<void(bool)> changed, int indent) {
    auto *box = new QCheckBox(text);
    box->setChecked(on);
    box->setEnabled(enabled);
    QObject::connect(box, &QCheckBox::toggled, box, [changed](bool value) { changed(value); });
    g.layout->addWidget(Indented(box, indent));
    return box;
}

QComboBox *Combo(const QString &label, const QStringList &items, int selected, bool enabled,
                 std::function<void(int)> changed, int indent) {
    auto *holder = new QWidget;
    auto *row = new QHBoxLayout(holder);
    row->setContentsMargins(indent, 0, 0, 0);
    auto *name = new QLabel(label);
    name->setMinimumWidth(160);
    name->setEnabled(enabled);
    auto *box = new QComboBox;
    box->addItems(items);
    box->setCurrentIndex(selected);
    box->setEnabled(enabled);
    box->setMinimumWidth(220);
    QObject::connect(box, QOverload<int>::of(&QComboBox::activated), box, [changed](int index) { changed(index); });
    row->addWidget(name);
    row->addWidget(box);
    row->addStretch(1);
    g.layout->addWidget(holder);
    return box;
}

QHBoxLayout *Line() {
    auto *row = new QHBoxLayout;
    row->setContentsMargins(0, 4, 0, 4);
    g.layout->addLayout(row);
    return row;
}

QPushButton *Push(const QString &text, std::function<void()> clicked, bool enabled, QBoxLayout *row) {
    auto *button = new QPushButton(text);
    button->setEnabled(enabled);
    QObject::connect(button, &QPushButton::clicked, button, [clicked] { clicked(); });
    if (row) {
        row->addWidget(button);
    } else {
        auto *line = Line();
        line->addWidget(button);
        line->addStretch(1);
    }
    return button;
}

QTreeWidget *List(const QStringList &columns, const std::vector<int> &widths, int height) {
    auto *list = new QTreeWidget;
    list->setHeaderLabels(columns);
    list->setRootIsDecorated(false);
    list->setUniformRowHeights(true);
    list->setSelectionMode(QAbstractItemView::SingleSelection);
    list->setMinimumHeight(height);
    for (size_t k = 0; k < widths.size(); k++) list->setColumnWidth(static_cast<int>(k), widths[k]);
    g.layout->addWidget(list);
    return list;
}

void Row(QTreeWidget *list, const QStringList &cells) { list->addTopLevelItem(new QTreeWidgetItem(cells)); }

int Selected(QTreeWidget *list) {
    auto *item = list ? list->currentItem() : nullptr;
    return item ? list->indexOfTopLevelItem(item) : -1;
}

bool Confirm(const QString &question, const QString &detail) {
    QMessageBox box(QMessageBox::Question, "Araso", question, QMessageBox::Ok | QMessageBox::Cancel, g.window);
    box.setInformativeText(detail);
    box.setDefaultButton(QMessageBox::Cancel);
    return box.exec() == QMessageBox::Ok;
}

}  // namespace settings

int RunSettings(const std::string &tab) {
    using namespace settings;
    // One settings window: an open one comes forward on the pane asked for.
    Json show = Json::object();
    show.set("show", tab);
    if (Send("settings", show.dump())) return 0;
    std::string error;
    if (!Bridge::shared().start(error, false)) {
        QMessageBox::critical(nullptr, "Araso", Q(error));
        return 1;
    }
    LoadModel();

    auto *window = new QWidget;
    g.window = window;
    window->setWindowTitle(T("Araso Settings"));
    window->setWindowIcon(QIcon::fromTheme("araso"));
    auto *frame = new QHBoxLayout(window);
    frame->setContentsMargins(0, 0, 0, 0);
    frame->setSpacing(0);
    sidebar = new QListWidget;
    sidebar->setFixedWidth(180);
    sidebar->setFrameShape(QFrame::NoFrame);
    for (const auto &pane : kPanes) sidebar->addItem(T(pane.title));
    scroll = new QScrollArea;
    scroll->setWidgetResizable(true);
    scroll->setFrameShape(QFrame::NoFrame);
    frame->addWidget(sidebar);
    frame->addWidget(scroll, 1);
    QObject::connect(sidebar, &QListWidget::currentRowChanged, window, [](int row) {
        if (row >= 0 && row != g.pane) ShowPane(row);
    });
    Listen(window);
    g.pane = PaneIndex(tab);
    sidebar->setCurrentRow(g.pane);
    BuildPane();
    window->resize(820, 640);
    window->show();
    // As on macOS: the window checks for updates when it opens.
    if (g.model["settings"]["checkForUpdates"].asBool(true)) CheckForUpdates();
    return qApp->exec();
}

}  // namespace araso
