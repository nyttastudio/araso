// The text field as the session sees it, for one fcitx5 input context. See docs/linux-port.md.
//
// fcitx5 keeps the word being typed out of the field: the app draws the preedit at the caret, and
// its surrounding text (when it sends one) is the field without it. The session (SnapshotClient)
// wants a field with the composition in it, as a Mac text field has its marked text, so the
// document here is the surrounding text with the preedit put in at the caret, in UTF-16 units from
// the start of what the app sent. The session's edits come back as ranges of that document, and are
// made in the app as deletions around the caret (in characters, as fcitx5 counts them), commits and
// the new preedit.
#pragma once

#include "Json.h"

#include <string>
#include <vector>

namespace araso {

std::u16string Utf16(const std::string &utf8);
std::string Utf8(const std::u16string &utf16);

class Document {
public:
    /// One thing to do in the app, in order.
    struct Edit {
        enum class Kind { Delete, Commit };
        Kind kind;
        /// Delete: from `offset` characters after the caret (negative: before it), `size` characters.
        int offset = 0;
        unsigned size = 0;
        /// Commit: the text.
        std::string text;
    };

    /// What the app says of the field now: its text and caret in characters, or nothing (`known`
    /// false) when it doesn't send surrounding text. The composition stays at the new caret.
    void setSurrounding(bool known, const std::string &text = {}, unsigned cursor = 0);

    /// `TextContext` for the session (`masked`: a password field).
    Json context(bool masked) const;

    /// Makes the reply's `ops` here and says what to make in the app.
    std::vector<Edit> apply(const Json &ops);

    /// The composition: its text, and the clause the candidates are for (UTF-16, within it; length
    /// 0 when there is none).
    const std::u16string &preedit() const { return preedit_; }
    int clauseStart() const { return clauseStart_; }
    int clauseLength() const { return clauseLength_; }
    bool composing() const { return !preedit_.empty(); }

    /// The app's field after the edits (no composition) and the caret in it, in characters: what
    /// its surrounding text will say, kept until it does.
    bool known() const { return known_; }
    std::string fieldText() const;
    unsigned fieldCursor() const;

    /// The app took the composition away (a reset it made itself): it is gone.
    void dropComposition();

private:
    bool known_ = false;
    /// The field with the composition in it at `caret_`.
    std::u16string text_;
    int caret_ = 0;
    std::u16string preedit_;
    int clauseStart_ = 0, clauseLength_ = 0;

    int compositionEnd() const { return caret_ + static_cast<int>(preedit_.size()); }
    static unsigned Characters(const std::u16string &text, int from, int to);
};

}  // namespace araso
