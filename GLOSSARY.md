# Araso

A macOS input method that decides, per word typed on QWERTY, whether the keys are English,
Korean (2-set) or Japanese romaji. These are the words the code and docs use for that.

## Language

**Korean shift key**:
A key whose shifted form is a different jamo on the 2-set layout: Q W E R T (ㅃ ㅉ ㄸ ㄲ ㅆ) and
O P (ㅒ ㅖ). A capital on any other key has no Korean meaning.
_Avoid_: double-consonant key, QWERTOP

**Lingering Shift** (늦게 뗀 Shift):
Shift still held for the one key right after a Korean shift key, so that key arrives as a capital
with no shifted jamo: a vowel after a double consonant (어떤 typed fast is `djEJs`), the next
consonant after a final ㅆ/ㄲ (있어 as `dlTDj`), or a consonant after ㅒ/ㅖ typed on a consonant
(예를 as `dPFmf`). It happens between lowercase keys: a word typed in capitals throughout (`TM`) is
an acronym, and ㅒ/ㅖ with no consonant before it (`PDF파일` as `PDFvkdlf`, `OAuth`) is English, not
a lingering Shift.
_Avoid_: stray Shift, Shift leak

**English-only capital**:
A capital that a lingering Shift does not explain (`Hello`, `API`, `dHello`). It makes the word
English before any scoring.

**Word**:
The run of keystrokes between two boundaries, read as one language. Shown underlined while it is
being typed.
_Avoid_: token (except in engine scoring), composition

**Boundary** (경계 글자):
The single Space, ASCII symbol or digit that ends a word and goes into the text with it.
_Avoid_: delimiter, separator, terminator

**Held word** (잡아 둔 단어):
A word kept underlined together with its boundary, still treated as the word being typed, in an
app set to hold words. Only a Space or a symbol is held, never a digit. A switch key changes the
word and Delete takes back only the boundary. It goes in when the next word starts, on most other
keys, and the moment ⌘ goes down (as every word being typed does, so a paste lands after it and
a delete on ⌘⌫ doesn't skip it).
_Avoid_: pending word, suspended word

**Switch key** (언어 바꾸기 키):
A key chosen per app that cycles the word being typed, or the word just committed, to its next
reading.
_Avoid_: toggle key, language key, Esc (it is only one possible switch key)

**Reading** (읽기):
One way of rendering a word's keys: English, English + Korean particle, Korean, Japanese.
_Avoid_: mode, interpretation

**Flip window** (확정한 뒤 고치기):
The moment right after a word was committed with its boundary, during which a switch key can
still change that word. It closes on any other key. Only apps that report the caret and the text
at it can offer it.
_Avoid_: undo window, post-commit edit
