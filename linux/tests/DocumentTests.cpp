// The document model alone: snapshots for the session, and the session's edits made as fcitx5 makes
// them (deletions around the caret in characters, commits, the preedit).
#include "Document.h"

#include <cstdio>
#include <string>

using araso::Document;
using araso::Json;

static int failures = 0;
#define EXPECT(condition)                                                              \
    do {                                                                               \
        if (!(condition)) {                                                            \
            std::fprintf(stderr, "%s:%d: expected %s\n", __FILE__, __LINE__, #condition); \
            ++failures;                                                                \
        }                                                                              \
    } while (0)

static Json Ops(std::initializer_list<Json> ops) {
    Json array = Json::array();
    for (const auto &op : ops) array.push(op);
    return array;
}

static Json Op(const char *kind, const char *text, int at = -1, int length = 0) {
    Json op = Json::object();
    op.set("kind", kind);
    op.set("text", text);
    if (at >= 0) {
        Json range = Json::array();
        range.push(at);
        range.push(length);
        op.set("replace", range);
    }
    return op;
}

static void composingInAKnownField() {
    Document document;
    document.setSurrounding(true, "ab", 2);
    EXPECT(document.context(false)["selection"][0].asInt() == 2);
    auto edits = document.apply(Ops({Op("mark", "ㅇ", 2, 0)}));
    EXPECT(edits.empty());
    EXPECT(araso::Utf8(document.preedit()) == "ㅇ");
    // The next key: the app's field hasn't changed, the composition sits at its caret.
    document.setSurrounding(true, "ab", 2);
    Json context = document.context(false);
    EXPECT(context["text"].asString() == "abㅇ");
    EXPECT(context["marked"][0].asInt() == 2 && context["marked"][1].asInt() == 1);
    EXPECT(context["selection"][0].asInt() == 3);
    edits = document.apply(Ops({Op("insert", "안녕", 2, 1)}));
    EXPECT(edits.size() == 1 && edits[0].kind == Document::Edit::Kind::Commit && edits[0].text == "안녕");
    EXPECT(!document.composing());
    EXPECT(document.fieldText() == "ab안녕" && document.fieldCursor() == 4);
}

static void switchingTheWordJustCommittedKeepsItsSpace() {
    Document document;
    document.setSurrounding(true, "안녕 ", 3);
    // `dkssud` replaces 안녕 (0, 2) while the Space after it stays after it.
    auto edits = document.apply(Ops({Op("insert", "dkssud", 0, 2)}));
    EXPECT(edits.size() == 2);
    EXPECT(edits[0].kind == Document::Edit::Kind::Delete && edits[0].offset == -3 && edits[0].size == 3);
    EXPECT(edits[1].kind == Document::Edit::Kind::Commit && edits[1].text == "dkssud ");
    EXPECT(document.fieldText() == "dkssud " && document.fieldCursor() == 7);
}

static void markingTheWordJustCommittedAgain() {
    Document document;
    document.setSurrounding(true, "x 안녕", 4);
    auto edits = document.apply(Ops({Op("mark", "dkssud", 2, 2)}));
    EXPECT(edits.size() == 1 && edits[0].offset == -2 && edits[0].size == 2);
    EXPECT(araso::Utf8(document.preedit()) == "dkssud");
    EXPECT(document.fieldText() == "x " && document.fieldCursor() == 2);
}

static void withoutTheFieldsTextOnlyTheCompositionChanges() {
    Document document;
    document.setSurrounding(false);
    Json context = document.context(false);
    EXPECT(context["unreadable"].asBool());
    document.apply(Ops({Op("mark", "ㅎ", 0, 0)}));
    document.setSurrounding(false);
    context = document.context(false);
    EXPECT(context["marked"][0].asInt() == 0 && context["marked"][1].asInt() == 1);
    // A range before what is known can't be reached: it is the composition's.
    auto edits = document.apply(Ops({Op("insert", "하", -5 + 5, 1)}));
    EXPECT(edits.size() == 1 && edits[0].text == "하");
}

static void charactersNotUnitsAroundTheCaret() {
    Document document;
    // 😀 is two UTF-16 units and one character.
    document.setSurrounding(true, "😀ab", 3);
    auto edits = document.apply(Ops({Op("insert", "X", 0, 4)}));
    EXPECT(edits.size() == 2 && edits[0].offset == -3 && edits[0].size == 3);
    EXPECT(document.fieldText() == "X");
}

static void theLineAfterTheCaretToo() {
    Document document;
    document.setSurrounding(true, "ab cd\nef", 2);
    Json context = document.context(false);
    EXPECT(context["text"].asString() == "ab cd");
    EXPECT(context["selection"][0].asInt() == 2);
    EXPECT(context["marksFromCaret"].asBool() && !context.has("marksAtCaret"));
}

static void fixingAWordInTheMiddleOfTheLine() {
    // `hello world again `, the caret in wo|rld: the steps InputSession takes where marked text
    // goes at the caret (marksFromCaret), then → over again and Return.
    Document document;
    document.setSurrounding(true, "hello world again ", 8);
    // The rest of the word over itself: the caret at its end.
    auto edits = document.apply(Ops({Op("insert", "rld", 8, 3)}));
    EXPECT(edits.size() == 2 && edits[0].offset == 0 && edits[0].size == 3 && edits[1].text == "rld");
    EXPECT(document.fieldCursor() == 11);
    // The word gone with the character before it put back: the caret at the word's start.
    edits = document.apply(Ops({Op("insert", " ", 5, 6)}));
    EXPECT(edits.size() == 2 && edits[0].offset == -6 && edits[0].size == 6 && edits[1].text == " ");
    EXPECT(document.fieldText() == "hello  again " && document.fieldCursor() == 6);
    // Marked there, read the next way.
    edits = document.apply(Ops({Op("mark", "재깅", -1, 0)}));
    EXPECT(edits.empty() && araso::Utf8(document.preedit()) == "재깅");
    document.setSurrounding(true, "hello  again ", 6);
    Json context = document.context(false);
    EXPECT(context["text"].asString() == "hello 재깅 again ");
    EXPECT(context["marked"][0].asInt() == 6 && context["marked"][1].asInt() == 2);
    // →: the marked text taken away, then marked again with the next word (its space and again),
    // over it.
    document.apply(Ops({Op("mark", "", -1, 0)}));
    EXPECT(document.fieldText() == "hello  again " && !document.composing());
    edits = document.apply(Ops({Op("mark", "재깅 미", 6, 6)}));
    EXPECT(edits.size() == 1 && edits[0].offset == 0 && edits[0].size == 6);
    EXPECT(document.fieldText() == "hello  " && araso::Utf8(document.preedit()) == "재깅 미");
    // Return: in, and the rest of the line over itself, the caret at its end.
    edits = document.apply(Ops({Op("insert", "재깅 미", -1, 0)}));
    EXPECT(edits.size() == 1 && edits[0].text == "재깅 미");
    EXPECT(document.fieldText() == "hello 재깅 미 " && document.fieldCursor() == 10);
    edits = document.apply(Ops({Op("insert", " ", 10, 1)}));
    EXPECT(edits.size() == 2 && edits[0].offset == 0 && edits[0].size == 1 && edits[1].text == " ");
    EXPECT(document.fieldText() == "hello 재깅 미 " && document.fieldCursor() == 11);
}

static void aReplysEditsAsOneDeletionAndOneCommit() {
    // The same steps in one reply, as the session sends them for one key: one deletion around the
    // caret (하세요 but 요 is ahead of it), no commit, and the preedit.
    Document document;
    document.setSurrounding(true, "안녕 하세요 있다 ", 5);
    auto edits = document.apply(Ops({Op("insert", "요", 5, 1), Op("insert", " ", 2, 4), Op("mark", "gktpdy", -1, 0)}));
    EXPECT(edits.size() == 1 && edits[0].kind == Document::Edit::Kind::Delete && edits[0].offset == -2 && edits[0].size == 3);
    EXPECT(document.fieldText() == "안녕  있다 " && document.fieldCursor() == 3);
    EXPECT(araso::Utf8(document.preedit()) == "gktpdy");
    // The app's state from before the deletion, arriving after it, changes nothing.
    document.setSurrounding(true, "안녕 하세요 있다 ", 5);
    EXPECT(document.context(false)["text"].asString() == "안녕 gktpdy 있다 ");
    // Return: the clause in and the rest of the line over itself, as one commit after one deletion.
    document.setSurrounding(true, "안녕  있다 ", 3);
    edits = document.apply(Ops({Op("insert", "gktpdy", -1, 0), Op("insert", " 있다 ", 9, 4)}));
    EXPECT(edits.size() == 2 && edits[0].kind == Document::Edit::Kind::Delete && edits[0].offset == 0 && edits[0].size == 4);
    EXPECT(edits[1].kind == Document::Edit::Kind::Commit && edits[1].text == "gktpdy 있다 ");
    EXPECT(document.fieldText() == "안녕 gktpdy 있다 " && document.fieldCursor() == 13);
}

static void aClauseWhileConverting() {
    Document document;
    document.setSurrounding(true, "", 0);
    Json op = Op("mark", "今日は", 0, 0);
    Json clause = Json::array();
    clause.push(0);
    clause.push(2);
    op.set("clause", clause);
    document.apply(Ops({op}));
    EXPECT(document.clauseStart() == 0 && document.clauseLength() == 2);
}

int main() {
    composingInAKnownField();
    switchingTheWordJustCommittedKeepsItsSpace();
    markingTheWordJustCommittedAgain();
    withoutTheFieldsTextOnlyTheCompositionChanges();
    charactersNotUnitsAroundTheCaret();
    aClauseWhileConverting();
    theLineAfterTheCaretToo();
    fixingAWordInTheMiddleOfTheLine();
    aReplysEditsAsOneDeletionAndOneCommit();
    if (failures) std::fprintf(stderr, "%d failed\n", failures);
    else std::printf("document tests passed\n");
    return failures ? 1 : 0;
}
