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
    if (failures) std::fprintf(stderr, "%d failed\n", failures);
    else std::printf("document tests passed\n");
    return failures ? 1 : 0;
}
