import Foundation
import Testing
@testable import ArasoCore

/// Korean on 3-set final (세벌식 최종): jamo on their own keys for each position, digits and
/// punctuation included, read through the same `HangulComposer.compose(keys:)` as 2-set.
@MainActor @Suite struct SebeolsikTests {
    static func compose(_ keys: String) -> String? {
        KoreanLayout.$override.withValue(.sebeolsikFinal) { HangulComposer.compose(keys: keys)?.text }
    }

    @Test func composesByPosition() {
        #expect(Self.compose("jfsheamfncj4") == "안녕하세요")
        #expect(Self.compose("kf2uf") == "갔다")      // ㅆ final on 2
        #expect(Self.compose("kkd") == "끼")          // ㄱㄱ is ㄲ
        #expect(Self.compose("j/f") == "와")          // ㅗ on / for compound vowels
        #expect(Self.compose("i9tmr") == "뭐해")
        #expect(Self.compose("m8") == "희")
        #expect(Self.compose("jtXjt") == "없어")      // ㅄ on ⇧X
        #expect(Self.compose("jd@uf") == "읽다")      // ㄺ on ⇧2
        #expect(Self.compose("k/rsofSjf") == "괜찮아")
        #expect(Self.compose("kfxx") == "갂")         // ㄱㄱ final is ㄲ
        // No 도깨비불: a vowel after a final starts its own (broken) syllable.
        #expect(Self.compose("kfxf") == "각ㅏ")
        #expect(Self.compose("jfshea!") == "안녕ㄲ")
    }

    @Test func numbersAndSymbolsArentKorean() {
        #expect(Self.compose("2026") == nil) // a number stays a number
        #expect(Self.compose("00") == "ㅋㅋ") // a reading to switch to: the engine reads a number
        #expect(Self.compose("0") == nil)
        #expect(Self.compose("Hello") == nil) // ⇧H is 0 in Korean: no jamo
        #expect(Self.compose("kf?") == nil)
    }

    @Test func twoSetIsUnchanged() {
        #expect(HangulComposer.compose(keys: "dkssud")?.text == "안녕")
        #expect(HangulComposer.compose(keys: "2026") == nil)
    }

    @Test func decides() {
        KoreanLayout.$override.withValue(.sebeolsikFinal) {
            let engine = SplittingEngine(base: sharedEngine, english: sharedEngine.english)
            func decide(_ keys: String) -> Decision { engine.decide(keys, context: DecisionContext()) }
            #expect(decide("jfsheamfncj4").output == "안녕하세요")
            #expect(decide("nnfwjgw").output == "쌀을")
            #expect(decide("jd3yex").output == "입력")
            #expect(decide("0tpd").output == "커피")
            #expect(decide("hello").output == "hello")
            #expect(decide("world").output == "world")
            #expect(decide("github" + "jc").output == "github에")
            #expect(decide("2026").output == "2026")
        }
    }

    /// Typing through a session, digits and symbols arriving as the app's printable keys; ⎋ in
    /// `text` is a switch key, ⌫ Delete.
    static func type(_ text: String, on layout: KoreanLayout = .sebeolsikFinal) -> String {
        KoreanLayout.$override.withValue(layout) {
            let field = FakeTextField()
            let store = FileManager.default.temporaryDirectory.appendingPathComponent("araso-3set-\(UUID().uuidString).json")
            let engine = DictionaryEngine(base: SplittingEngine(base: sharedEngine, english: sharedEngine.english), storeURL: store)
            let session = InputSession(engine: engine, policies: AppPolicies(overrides: [:]))
            for ch in text {
                let key: InputSession.Key = ch == "⎋" ? .cycle : ch == "⌫" ? .delete : ch.isLetter ? .letter(ch) : .printable(ch)
                guard !session.handle(key, client: field), key != .cycle else { continue }
                // A key the session passes on is the app's: Delete takes the character before the caret.
                if key == .delete {
                    if field.cursor > 0 { field.insertText("", replacing: NSRange(location: field.cursor - 1, length: 1)) }
                } else {
                    field.insertText(String(ch), replacing: nil)
                }
            }
            return field.text
        }
    }

    @Test func digitsAndSymbolsTypeJamoInsideAWord() {
        #expect(Self.type("jfshea hello ") == "안녕 hello ")
        #expect(Self.type("kf2uf ") == "갔다 ")       // 2 is the final ㅆ
        #expect(Self.type(";f3 ") == "밥 ")           // a word starts on ; (ㅂ)
        #expect(Self.type("0tpd ") == "커피 ")        // and on 0 (ㅋ)
        #expect(Self.type("mr2uf. ") == "했다. ")
        #expect(Self.type("mfqngjvf3 ") == "핫스왑 ") // 3 is the final ㅂ: 왑 is only in rare words (나왑)
        #expect(Self.type("or3't ") == "챕터 ")
        #expect(Self.type("0e3hduf ") == "켭니다 ")
        #expect(Self.type("ldqkb#jgs ") == "짓궂은 ")    // # is the final ㅈ
        #expect(Self.type("jfspf! ") == "안팎 ")
    }

    /// #35: right after a Korean word, and after the symbols that follow it, a key types what
    /// 3-set final has on it (⇧B ?, ⇧/ !, ⇧L 3, [ (); anywhere else what QWERTY has.
    @Test func symbolsAfterKoreanAreThreeSets() {
        #expect(Self.type("lfw ldhr2jtB ") == "잘 지냈어? ")
        #expect(Self.type("jvyrsifsjduf? ") == "오랜만이다! ")    // ⇧/ is !
        #expect(Self.type("jvyrsifsjduf?B ") == "오랜만이다!? ")
        #expect(Self.type("jvyrsifsjduf.B ") == "오랜만이다.? ") // after punctuation QWERTY types too
        #expect(Self.type("ldLH ") == "지30 ")                     // ⇧L ⇧H: digits
        #expect(Self.type("mfqngjvf3[") == "핫스왑(")
        #expect(Self.type("mfqngjvf3N ") == "핫스왑- ")
        // Not at a word's start, after English or in a URL.
        #expect(Self.type("jfsheamfncj4 Bob ") == "안녕하세요 Bob ")
        #expect(Self.type("hello? ") == "hello? ")
        #expect(Self.type("hello[B] ") == "hello[B] ")
        #expect(Self.type("jvyrsifsjduf? B ") == "오랜만이다! B ")
        #expect(Self.type("kgbB ") == "kgbB ")                 // 그ㅜ isn't a word
        #expect(Self.type("mmB ") == "ㅎㅎ? ")
    }

    @Test func aSwitchKeyTakesTheSymbolBackToTheKey() {
        #expect(Self.type("ldhr2jtB⎋") == "ldhr2jtB")
        #expect(Self.type("ldhr2jtB⎋⎋") == "지냈어?")
    }

    /// 0 is ㅋ: after Korean, 0000 is ㅋㅋㅋㅋ; elsewhere a number, which a switch key makes ㅋㅋㅋㅋ.
    @Test func zerosLaughAfterKorean() {
        #expect(Self.type("lfw 0000 ") == "잘 ㅋㅋㅋㅋ ")
        #expect(Self.type("lfw0000 ") == "잘ㅋㅋㅋㅋ ")
        #expect(Self.type("lfw 0000? ") == "잘 ㅋㅋㅋㅋ! ")
        #expect(Self.type("0000 ") == "0000 ")
        #expect(Self.type("0000⎋ ") == "ㅋㅋㅋㅋ ")
        #expect(Self.type("lfw 0000 ⎋") == "잘 0000 ")
        #expect(Self.type("lfw 0 ") == "잘 0 ")            // one 0 is a number
        #expect(Self.type("lfw 1,000 ") == "잘 1,000 ")
        #expect(Self.type("lfw 10:00 ") == "잘 10:00 ")
        #expect(Self.type("lfw 100 ") == "잘 100 ")
    }

    /// 390: the same jamo but fewer finals of their own (ㄵ is ㄴ then ㅈ on ⇧1), QWERTY's symbols
    /// on the unshifted keys and its digits as a keypad.
    @Test func sebeolsik390() {
        func type(_ text: String) -> String { Self.type(text, on: .sebeolsik390) }
        #expect(type("jfs!jf ") == "앉아 ")              // ㄴ + ㅈ
        #expect(type("ufDjgs ") == "닭은 ")              // ⇧D is ㄺ
        #expect(type("kfXjd ") == "값이 ")
        #expect(type("htxqjd ") == "넋이 ")              // ㄱ + ㅅ, where 최종 has ⇧V
        #expect(type("mfqngjvf3 ") == "핫스왑 ")
        #expect(type("jfsheamfncj4B ") == "안녕하세요! ")   // ⇧B is !
        #expect(type("lfw ldhr2jt? ") == "잘 지냈어? ")     // ? is QWERTY's
        #expect(type("lcM ") == "제1 ")                  // ⇧M is 1
        #expect(type("lfw 0000 ") == "잘 ㅋㅋㅋㅋ ")
        #expect(type("hello[B] ") == "hello[B] ")
        #expect(type("ldhr2jtB⎋") == "ldhr2jtB")
    }

    @Test func deleteTakesBackTheLastJamo() {
        KoreanLayout.$override.withValue(.sebeolsikFinal) {
            let field = FakeTextField()
            let store = FileManager.default.temporaryDirectory.appendingPathComponent("araso-3set-\(UUID().uuidString).json")
            let engine = DictionaryEngine(base: SplittingEngine(base: sharedEngine, english: sharedEngine.english), storeURL: store)
            let session = InputSession(engine: engine, policies: AppPolicies(overrides: [:]))
            for ch in "kf2uf" {
                let key: InputSession.Key = ch.isLetter ? .letter(ch) : .printable(ch)
                if !session.handle(key, client: field) { field.insertText(String(ch), replacing: nil) }
            }
            _ = session.handle(.delete, client: field)
            #expect(field.text == "갔ㄷ")
            _ = session.handle(.delete, client: field)
            #expect(field.text == "갔")
            // 갔 was committed once ㄷ began the next syllable: it goes whole, as on 2-set.
            _ = session.handle(.delete, client: field)
            #expect(field.text == "")
        }
    }

    /// A jamo deleted from a word's first syllable and typed again joins it (#38): 안 → 아 → 안,
    /// not 아ㄴ; 하 → ㅎ → 하, not ㅎㅏ.
    @Test func retypingInTheFirstSyllableJoinsIt() {
        #expect(Self.type("jfs⌫shea") == "안녕")
        #expect(Self.type("mf⌫f") == "하")
        #expect(Self.type("jfshea⌫a") == "안녕")
        // Nothing being typed: the app deletes, here the space after 안.
        #expect(Self.type("jfs ⌫") == "안")
    }

    @Test func symbolsThatDontFitEndTheWord() {
        #expect(Self.type("jfshea! ") == "안녕! ")    // ㄲ can't follow 녕's ㅇ: it is the !
        #expect(Self.type("jfsheamfncj4! ") == "안녕하세요! ") // 욖 isn't a syllable anyone types
        #expect(Self.type(";f! ") == "밖 ")             // 밖 is
        #expect(Self.type("hello! ") == "hello! ")
        #expect(Self.type("100 ") == "100 ")          // a number stays a number
        #expect(Self.type("2026 ") == "2026 ")
        #expect(Self.type("2026 0tpd ") == "2026 커피 ") // after a space 0 starts a word again
        #expect(Self.type("it's ") == "it's ")
    }
}
