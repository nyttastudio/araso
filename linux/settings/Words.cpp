// The Dictionary and Try Typing panes (windows/host/SettingsWords.cpp; DictionaryPane.swift and
// TypingPane.swift on macOS).
#include "Settings.h"

#include <QButtonGroup>
#include <QComboBox>
#include <QFile>
#include <QDialog>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QRadioButton>
#include <QTimer>
#include <QTreeWidget>
#include <QVBoxLayout>

#include <cstdlib>

namespace araso {
namespace settings {

namespace {

QString LanguageName(const std::string &language) {
    if (language == "english") return T("English");
    if (language == "korean") return T("Korean");
    if (language == "mixed") return T("Mixed");
    if (language == "japanese") return T("Japanese");
    return T("My text");
}

QString StatusName(const std::string &status) {
    if (status == "added") return T("Added");
    if (status == "once") return T("Corrected once");
    return T("Remembered");
}

const char *kFilters[] = {"all", "added", "remembered", "once"};

/// Fills the list with the words the filter and the search let through.
void FillWords() {
    if (!g.wordList) return;
    g.wordList->clear();
    g.shownWords.clear();
    QString search = g.search.toLower();
    for (const Json &word : g.model["words"].items()) {
        std::string status = word["status"].asString();
        if (g.filter > 0 && status != kFilters[g.filter]) continue;
        QString keys = Q(word["keys"].asString()), text = Q(word["text"].asString());
        if (!search.isEmpty() && !keys.toLower().contains(search) && !text.toLower().contains(search)) continue;
        QStringList apps;
        for (const Json &app : word["apps"].items()) apps << Q(app.asString());
        const Json &days = word["daysLeft"];
        Row(g.wordList, {keys, text + "  ·  " + LanguageName(word["language"].asString()), StatusName(status),
                         apps.isEmpty() ? T("Every app") : apps.join(", "),
                         days.isNumber() ? T("%ld days", {std::to_string(days.asInt())}) : QString("—")});
        g.shownWords.push_back(word);
    }
}

const Json *SelectedWord() {
    int row = Selected(g.wordList);
    return row >= 0 && row < static_cast<int>(g.shownWords.size()) ? &g.shownWords[static_cast<size_t>(row)] : nullptr;
}

}  // namespace

// MARK: - Dictionary

void BuildDictionary() {
    int counts[4] = {0, 0, 0, 0};
    for (const Json &word : g.model["words"].items()) {
        counts[0]++;
        std::string status = word["status"].asString();
        for (int k = 1; k < 4; k++) if (status == kFilters[k]) counts[k]++;
    }
    auto *top = Line();
    auto *filter = new QComboBox;
    filter->addItems({T("All %ld", {std::to_string(counts[0])}), T("Added %ld", {std::to_string(counts[1])}),
                      T("Remembered %ld", {std::to_string(counts[2])}), T("Corrected once %ld", {std::to_string(counts[3])})});
    filter->setCurrentIndex(g.filter);
    QObject::connect(filter, QOverload<int>::of(&QComboBox::activated), filter, [](int index) {
        g.filter = std::max(0, index);
        Rebuild();
    });
    auto *search = new QLineEdit(g.search);
    search->setPlaceholderText(T("Search"));
    search->setMinimumWidth(220);
    QObject::connect(search, &QLineEdit::textChanged, search, [](const QString &text) {
        g.search = text;
        FillWords();
    });
    top->addWidget(filter);
    top->addWidget(search);
    top->addStretch(1);
    Push(T("Add…"), [] { EditWord(nullptr, ""); }, true, top);
    const char *notes[] = {"These keys come out as written here, also with a particle after them.",
                           "Words you added here. They always come out this way.",
                           "Words you switched the same way twice. They always come out this way.",
                           "Words you switched once. They only lean that way, and are forgotten after 30 days unless you switch or type them again."};
    Note(T(notes[g.filter]));

    g.wordList = List({T("Keys"), T("Result"), T("Status"), T("Apps"), T("Expires")}, {120, 170, 100, 110, 70}, 230);
    FillWords();
    QObject::connect(g.wordList, &QTreeWidget::itemDoubleClicked, g.wordList, [](QTreeWidgetItem *, int) {
        if (const Json *word = SelectedWord()) EditWord(word, "");
    });
    if (g.shownWords.empty()) {
        Note(g.model["words"].size() == 0 ? T("No words yet") : T("No matches"));
        if (g.model["words"].size() == 0) {
            Note(T("Add a word with +, or switch a word that came out wrong with the language switch key: corrected the same way twice, it's remembered here."));
        }
    }
    auto *row = Line();
    Push(T("Edit…"), [] { if (const Json *word = SelectedWord()) EditWord(word, ""); }, true, row);
    Push(T("Keep for Good"), [] {
        const Json *word = SelectedWord();
        if (!word || (*word)["status"].asString() == "added") return;
        Json change = Json::object();
        change.set("keepWord", (*word)["id"]);
        Apply(change);
    }, true, row);
    Push(T("Remove"), [] {
        const Json *word = SelectedWord();
        if (!word) return;
        Json change = Json::object();
        change.set("removeWord", (*word)["id"]);
        Apply(change);
    }, true, row);
    row->addStretch(1);
    Push(T("Forget Learned Words…"), [] {
        if (!Confirm(T("Forget every learned word?"), T("Words you added stay. This can't be undone."))) return;
        Json change = Json::object();
        change.set("forgetLearned", true);
        Apply(change);
    }, true, row);
}

/// Adds a word (`word` nil) or changes one: the keys as typed, the reading they come out as, and
/// the app they're for.
void EditWord(const Json *word, const std::string &keys) {
    Json original = word ? *word : Json();
    QDialog dialog(g.window);
    dialog.setWindowTitle(word ? T("Change Word") : T("Add to Dictionary"));
    auto *column = new QVBoxLayout(&dialog);
    auto *keysTitle = new QLabel(T("Type the keys"));
    QFont bold = keysTitle->font();
    bold.setBold(true);
    keysTitle->setFont(bold);
    column->addWidget(keysTitle);
    auto *field = new QLineEdit(Q(word ? original["keys"].asString() : keys));
    // The keys go in as typed, not through an input method (Araso's own included).
    field->setAttribute(Qt::WA_InputMethodEnabled, false);
    column->addWidget(field);
    auto *hint = new QLabel(T("Type the keys as you would on the English layout. They go in as typed, not through an input method."));
    hint->setWordWrap(true);
    column->addWidget(hint);
    auto *outTitle = new QLabel(T("Comes out as"));
    outTitle->setFont(bold);
    column->addWidget(outTitle);
    // Up to four readings, refilled as the keys change.
    QRadioButton *choices[4];
    auto *group = new QButtonGroup(&dialog);
    std::vector<std::string> languages(4);
    std::string chosen = word ? original["language"].asString() : "english";
    for (int k = 0; k < 4; k++) {
        choices[k] = new QRadioButton;
        group->addButton(choices[k], k);
        column->addWidget(choices[k]);
        QObject::connect(choices[k], &QRadioButton::toggled, &dialog, [&languages, &chosen, k](bool on) {
            if (on) chosen = languages[static_cast<size_t>(k)];
        });
    }
    auto refill = [&]() {
        Json request = Json::object();
        request.set("op", "readings");
        request.set("keys", field->text().toStdString());
        Json answer = Request(request);
        const Json &list = answer["choices"];
        bool found = false;
        std::string keep = chosen;
        for (int k = 0; k < 4; k++) {
            bool shown = k < static_cast<int>(list.size());
            languages[static_cast<size_t>(k)] = shown ? list[k]["language"].asString() : "";
            choices[k]->setText(shown ? LanguageName(languages[static_cast<size_t>(k)]) + "    " + Q(list[k]["text"].asString()) : "");
            choices[k]->setVisible(shown);
            if (shown && languages[static_cast<size_t>(k)] == keep) {
                choices[k]->setChecked(true);
                found = true;
            }
        }
        chosen = keep;
        if (!found && list.size() > 0) {
            chosen = languages[0];
            choices[0]->setChecked(true);
        }
    };
    QObject::connect(field, &QLineEdit::textChanged, &dialog, [&refill](const QString &) { refill(); });
    auto *appRow = new QHBoxLayout;
    appRow->addWidget(new QLabel(T("App")));
    auto *app = new QComboBox;
    app->setEditable(true);
    app->addItem(T("Every app"));
    for (const Json &item : g.model["apps"].items()) app->addItem(Q(item["app"].asString()));
    const Json &apps = original["apps"];
    if (apps.size() > 0) app->setEditText(Q(apps[0].asString()));
    appRow->addWidget(app, 1);
    column->addLayout(appRow);

    auto *buttons = new QHBoxLayout;
    if (word) {
        auto *remove = new QPushButton(T("Remove"));
        QObject::connect(remove, &QPushButton::clicked, &dialog, [&] {
            Json change = Json::object();
            change.set("removeWord", original["id"]);
            Apply(change);
            dialog.reject();
        });
        buttons->addWidget(remove);
    }
    buttons->addStretch(1);
    auto *cancel = new QPushButton(T("Cancel"));
    auto *save = new QPushButton(word ? T("Save") : T("Add"));
    save->setDefault(true);
    QObject::connect(cancel, &QPushButton::clicked, &dialog, &QDialog::reject);
    QObject::connect(save, &QPushButton::clicked, &dialog, &QDialog::accept);
    buttons->addWidget(cancel);
    buttons->addWidget(save);
    column->addLayout(buttons);
    refill();
    field->setFocus();
    dialog.resize(460, 380);
    if (dialog.exec() != QDialog::Accepted) return;

    std::string typed = field->text().toStdString();
    if (typed.empty()) return;
    Json entry = Json::object();
    entry.set("keys", typed);
    entry.set("as", chosen.empty() ? "english" : chosen);
    entry.set("from", "user");
    QString appName = app->currentText().trimmed();
    if (!appName.isEmpty() && appName != T("Every app")) {
        Json list = Json::array();
        list.push(appName.toLower().toStdString());
        entry.set("apps", list);
    }
    Json change = Json::object();
    change.set("addWord", entry);
    if (word) change.set("replacing", original["id"]);
    Apply(change);
}

// MARK: - Try Typing

namespace {

void FillTraces() {
    if (!g.traceList) return;
    g.traceList->clear();
    for (auto it = g.traces.rbegin(); it != g.traces.rend(); ++it) {
        const Json &trace = *it;
        Row(g.traceList, {Q(trace["keys"].asString()), Q(trace["output"].asString()), LanguageName(trace["language"].asString()),
                          QString::number(trace["confidence"].asNumber(), 'f', 2), Q(trace["explanation"].asString())});
    }
}

}  // namespace

void AddTrace(const Json &trace) {
    if (!trace.isObject()) return;
    // A word still being typed replaces the one before it until the word is done.
    if (!g.traces.empty() && g.traces.back()["partial"].asBool()) g.traces.pop_back();
    g.traces.push_back(trace);
    if (g.traces.size() > 50) g.traces.erase(g.traces.begin());
    FillTraces();
}

void BuildTyping() {
    Note(T("Type here on the English layout, e.g. dkssud hello"));
    // Typed through fcitx5 like any app's field: the addon reports how each word was decided
    // here, since this program is its own (`ownApp`).
    auto *field = new QPlainTextEdit(g.typed);
    field->setMinimumHeight(110);
    field->setMaximumHeight(140);
    QObject::connect(field, &QPlainTextEdit::textChanged, field, [field] {
        g.typed = field->toPlainText();
        // The typing test reads what the field holds (linux/scripts/typing-test).
        if (const char *out = std::getenv("ARASO_TYPING_OUT")) {
            QFile file(out);
            if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) file.write(g.typed.toUtf8());
        }
    });
    g.layout->addWidget(field);
    Note(T("The language switch key changes the word's reading, also right after the word."));
    auto *row = Line();
    Push(T("Clear"), [field] {
        field->clear();
        g.traces.clear();
        FillTraces();
        field->setFocus();
    }, true, row);
    Push(T("Add to Dictionary…"), [] {
        int selected = Selected(g.traceList);
        if (selected < 0 || selected >= static_cast<int>(g.traces.size())) return;
        EditWord(nullptr, g.traces[g.traces.size() - 1 - static_cast<size_t>(selected)]["keys"].asString());
    }, true, row);
    row->addStretch(1);
    Heading(T("How it was decided"));
    g.traceList = List({T("Keys"), T("Result"), T("Language"), T("Confidence"), T("Why")}, {110, 120, 80, 80, 260}, 190);
    FillTraces();
    if (g.traces.empty()) Note(T("Type a word above to see its scores."));
    // Once the pane is in the window: a widget not shown yet can't take the focus.
    QTimer::singleShot(0, field, [field] { field->setFocus(); });
}

}  // namespace settings
}  // namespace araso
