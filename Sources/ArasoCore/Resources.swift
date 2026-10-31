import Foundation

/// Finds data files both inside the installed app (Araso.app/Contents/Resources)
/// and in the source tree during development and tests.
///
/// SPM resource bundles are avoided on purpose: their accessor looks for the bundle
/// at the .app root, which is outside the signed Contents and breaks code signing.
public enum Resources {
    /// Set by a host that keeps the data files elsewhere (Windows: `Resources` beside ArasoHost.exe).
    nonisolated(unsafe) public static var directory: URL?

    /// Source tree root, from this file's location (Sources/ArasoCore/Resources.swift).
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func url(_ name: String, development: URL) -> URL? {
        var candidates: [URL] = []
        if let directory { candidates.append(directory.appendingPathComponent(name)) }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
        if let dir = ProcessInfo.processInfo.environment["ARASO_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        candidates.append(development)
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Kana trigram counts (tools/build_kana_model.py).
    public static var kanaModel: URL? {
        url("kana_trigrams.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/kana_trigrams.txt"))
    }

    /// Character trigrams of written Japanese, for reranking conversions (build_text_model.py).
    public static var textModel: URL? {
        url("text_trigrams.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/text_trigrams.txt"))
    }

    /// English words with their SCOWL level, 10 (most common) to 60 (build_english_words.py).
    public static var englishWords: URL? {
        url("english_words.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/english_words.txt"))
    }

    /// English acronyms of SCOWL up to size 70 (build_english_acronyms.py).
    public static var englishAcronyms: URL? {
        url("english_acronyms.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/english_acronyms.txt"))
    }

    /// Webster's Second International (web2, public domain): the letter trigrams' spellings where
    /// the system has no /usr/share/dict/words (Windows, Linux).
    public static var englishSpelling: URL? {
        url("english_spelling.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/english_spelling.txt"))
    }

    /// Korean words seen in sentences, with counts (Tatoeba; build_korean_words.py).
    public static var koreanWords: URL? {
        url("korean_words.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/korean_words.txt"))
    }

    /// Korean words of two or more syllables, loanwords included (FrequencyWords;
    /// build_korean_vocabulary.py): splitting `hello월드`, and the heuristic's Korean word floor.
    public static var koreanVocabulary: URL? {
        url("korean_vocabulary.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/korean_vocabulary.txt"))
    }

    /// Korean syllable counts from sentences (Tatoeba).
    public static var koreanSyllables: URL? {
        url("korean_syllables.txt", development: packageRoot.appendingPathComponent("Sources/ArasoCore/Data/korean_syllables.txt"))
    }

    /// AzooKey's dictionary directory (Apache-2.0).
    public static var japaneseDictionary: URL? {
        url("Dictionary", development: packageRoot.appendingPathComponent(
            ".build/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary"))
    }
}
