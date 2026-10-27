#include "Document.h"

#include <algorithm>

namespace araso {

namespace {

/// How much of the field before the composition goes to the session (TextContext's 256 units).
constexpr int kBefore = 256;

bool IsLowSurrogate(char16_t unit) { return unit >= 0xDC00 && unit <= 0xDFFF; }

}  // namespace

std::u16string Utf16(const std::string &utf8) {
    std::u16string out;
    out.reserve(utf8.size());
    for (size_t i = 0; i < utf8.size();) {
        unsigned char c = static_cast<unsigned char>(utf8[i]);
        char32_t point;
        size_t length;
        if (c < 0x80) { point = c; length = 1; }
        else if ((c >> 5) == 0x6) { point = c & 0x1F; length = 2; }
        else if ((c >> 4) == 0xE) { point = c & 0x0F; length = 3; }
        else if ((c >> 3) == 0x1E) { point = c & 0x07; length = 4; }
        else { ++i; continue; }  // not UTF-8: skipped
        if (i + length > utf8.size()) break;
        for (size_t k = 1; k < length; ++k) point = (point << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        i += length;
        if (point >= 0x10000) {
            point -= 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (point >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (point & 0x3FF)));
        } else {
            out.push_back(static_cast<char16_t>(point));
        }
    }
    return out;
}

std::string Utf8(const std::u16string &utf16) {
    std::string out;
    out.reserve(utf16.size() * 3);
    for (size_t i = 0; i < utf16.size(); ++i) {
        char32_t point = utf16[i];
        if (point >= 0xD800 && point <= 0xDBFF && i + 1 < utf16.size() && IsLowSurrogate(utf16[i + 1])) {
            point = 0x10000 + ((point - 0xD800) << 10) + (utf16[i + 1] - 0xDC00);
            ++i;
        }
        if (point < 0x80) {
            out.push_back(static_cast<char>(point));
        } else if (point < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (point >> 6)));
            out.push_back(static_cast<char>(0x80 | (point & 0x3F)));
        } else if (point < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (point >> 12)));
            out.push_back(static_cast<char>(0x80 | ((point >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (point & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (point >> 18)));
            out.push_back(static_cast<char>(0x80 | ((point >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((point >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (point & 0x3F)));
        }
    }
    return out;
}

unsigned Document::Characters(const std::u16string &text, int from, int to) {
    unsigned count = 0;
    for (int i = std::max(0, from); i < to && i < static_cast<int>(text.size()); ++i) {
        if (!IsLowSurrogate(text[static_cast<size_t>(i)])) ++count;
    }
    return count;
}

void Document::setSurrounding(bool known, const std::string &text, unsigned cursor) {
    known_ = known;
    if (!known) {
        // Only the composition is known: the session reads nothing before it.
        text_ = preedit_;
        caret_ = 0;
        return;
    }
    std::u16string field = Utf16(text);
    // The caret in characters → UTF-16 units.
    size_t at = 0;
    for (unsigned n = 0; n < cursor && at < field.size(); ++n) {
        at += (field[at] >= 0xD800 && field[at] <= 0xDBFF && at + 1 < field.size()) ? 2 : 1;
    }
    text_ = field.substr(0, at) + preedit_ + field.substr(at);
    caret_ = static_cast<int>(at);
}

Json Document::context(bool masked) const {
    int end = compositionEnd();
    int start = std::max(0, caret_ - kBefore);
    if (start > 0 && IsLowSurrogate(text_[static_cast<size_t>(start)])) --start;
    Json context = Json::object();
    Json selection = Json::array();
    selection.push(end);
    selection.push(0);
    context.set("selection", selection);
    if (!preedit_.empty()) {
        Json marked = Json::array();
        marked.push(caret_);
        marked.push(static_cast<int>(preedit_.size()));
        context.set("marked", marked);
    }
    context.set("text", Utf8(text_.substr(static_cast<size_t>(start), static_cast<size_t>(end - start))));
    context.set("start", start);
    if (!known_) context.set("unreadable", true);
    if (masked) context.set("masked", true);
    return context;
}

std::vector<Document::Edit> Document::apply(const Json &ops) {
    std::vector<Edit> edits;
    auto remove = [&](int offset, unsigned size) {
        if (size) edits.push_back({Edit::Kind::Delete, offset, size, {}});
    };
    for (const Json &op : ops.items()) {
        bool mark = op["kind"].asString() == "mark";
        std::u16string text = Utf16(op["text"].asString());
        int size = static_cast<int>(text_.size());
        int end = compositionEnd();
        int from = caret_, to = end;
        const Json &replace = op["replace"];
        if (replace.isArray() && replace.size() == 2) {
            from = std::clamp(replace[0].asInt(), 0, size);
            to = std::clamp(replace[0].asInt() + replace[1].asInt(), from, size);
        }
        if (!known_) {
            // Without the field's text only the composition can be replaced.
            from = std::clamp(from, caret_, end);
            to = std::clamp(to, from, end);
        }
        if (!mark) {
            // What the range leaves between it and the composition goes in again after the text (a
            // word switched after the Space that followed it keeps its Space).
            int low = std::min(from, caret_), high = std::max(to, end);
            std::u16string put = text_.substr(static_cast<size_t>(low), static_cast<size_t>(std::max(0, from - low))) + text +
                                 text_.substr(static_cast<size_t>(to), static_cast<size_t>(std::max(0, high - to)));
            // The composition was never in the app's field: only the rest is deleted there (one the
            // range didn't cover is part of `put`, and goes in with it).
            remove(-static_cast<int>(Characters(text_, low, caret_)),
                   Characters(text_, low, caret_) + Characters(text_, end, high));
            if (!put.empty()) edits.push_back({Edit::Kind::Commit, 0, 0, Utf8(put)});
            text_ = text_.substr(0, static_cast<size_t>(low)) + put + text_.substr(static_cast<size_t>(high));
            caret_ = low + static_cast<int>(put.size());
            preedit_.clear();
            clauseStart_ = clauseLength_ = 0;
            continue;
        }
        // A new composition, always at the caret: what the range covers of the field goes, and
        // what lies between the range and the caret stays before the composition.
        if (to <= caret_) {
            remove(-static_cast<int>(Characters(text_, from, caret_)), Characters(text_, from, to));
            text_ = text_.substr(0, static_cast<size_t>(from)) + text_.substr(static_cast<size_t>(to), static_cast<size_t>(caret_ - to)) +
                    text + text_.substr(static_cast<size_t>(end));
            caret_ = from + (caret_ - to);
        } else if (from >= end) {
            remove(static_cast<int>(Characters(text_, end, from)), Characters(text_, from, to));
            text_ = text_.substr(0, static_cast<size_t>(caret_)) + text + text_.substr(static_cast<size_t>(end), static_cast<size_t>(from - end)) +
                    text_.substr(static_cast<size_t>(to));
        } else {
            int low = std::min(from, caret_), high = std::max(to, end);
            remove(-static_cast<int>(Characters(text_, low, caret_)),
                   Characters(text_, low, caret_) + Characters(text_, end, high));
            text_ = text_.substr(0, static_cast<size_t>(low)) + text + text_.substr(static_cast<size_t>(high));
            caret_ = low;
        }
        preedit_ = text;
        clauseStart_ = clauseLength_ = 0;
        const Json &clause = op["clause"];
        if (clause.isArray() && clause.size() == 2 && clause[1].asInt() > 0) {
            clauseStart_ = std::clamp(clause[0].asInt(), 0, static_cast<int>(text.size()));
            clauseLength_ = std::clamp(clause[1].asInt(), 0, static_cast<int>(text.size()) - clauseStart_);
        }
    }
    return edits;
}

std::string Document::fieldText() const {
    return Utf8(text_.substr(0, static_cast<size_t>(caret_)) + text_.substr(static_cast<size_t>(compositionEnd())));
}

unsigned Document::fieldCursor() const { return Characters(text_, 0, caret_); }

void Document::dropComposition() {
    text_.erase(static_cast<size_t>(caret_), preedit_.size());
    preedit_.clear();
    clauseStart_ = clauseLength_ = 0;
}

}  // namespace araso
