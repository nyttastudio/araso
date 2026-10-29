import Foundation
import KanaKanjiConverterModule

/// One conversion candidate for (a prefix of) the hiragana being converted.
public struct ConversionCandidate: Equatable, Sendable {
    public let text: String
    /// How many kana from the start this candidate covers. Less than the whole
    /// reading means choosing it converts the first clause and keeps converting the rest.
    public let kanaCount: Int
    /// A completion of the reading (ゆーちゅ → YouTube) rather than a conversion of it: offered
    /// in the candidate list, never shown by live conversion.
    public var isPrediction = false

    public init(text: String, kanaCount: Int, isPrediction: Bool = false) {
        self.text = text
        self.kanaCount = kanaCount
        self.isPrediction = isPrediction
    }
}

/// Kana → kanji conversion. `AppleJapaneseConverter` in the app (`AzooKeyConverter` where macOS's
/// engine can't be loaded, or by choice); fakes in tests.
@MainActor
public protocol JapaneseConverter: AnyObject {
    func candidates(for kana: String) -> [ConversionCandidate]
    /// The user committed `candidate`: remember it so it ranks higher next time.
    func learn(_ candidate: ConversionCandidate, for kana: String)
    /// Persist anything learned (called on deactivation).
    func save()
    /// Candidates for all of `kana` that `candidates(for:)` leaves out, in the engine's order: the
    /// candidate window lists them after it, as macOS's Japanese input lists every homophone.
    func moreCandidates(for kana: String) -> [ConversionCandidate]
}

extension JapaneseConverter {
    public func moreCandidates(for kana: String) -> [ConversionCandidate] { [] }
}

/// AzooKey's dictionary converter (code MIT, dictionary Apache-2.0), without the
/// neural Zenzai model. Learning data lives in Application Support/Araso/azooKey.
@MainActor
public final class AzooKeyConverter: JapaneseConverter {
    private let converter = KanaKanjiConverter()
    private let options: ConvertRequestOptions
    /// Candidates of the last request, by text, so `learn` can hand the original back.
    private var lastCandidates: [String: Candidate] = [:]

    public init?(dictionary: URL? = Resources.japaneseDictionary, memory: URL? = AzooKeyConverter.memoryURL,
                 nBest: Int = 20) {
        guard let dictionary, let memory else { return nil }
        try? FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        options = ConvertRequestOptions(
            N_best: nBest,
            requireJapanesePrediction: false,
            requireEnglishPrediction: false,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            learningType: .inputAndOutput,
            dictionaryResourceURL: dictionary,
            memoryDirectoryURL: memory,
            sharedContainerURL: memory,
            textReplacer: .empty,
            specialCandidateProviders: [],
            metadata: .init(versionString: "Araso")
        )
    }

    nonisolated public static var memoryURL: URL? {
        SupportDirectory.url?.appendingPathComponent("azooKey", isDirectory: true)
    }

    public func candidates(for kana: String) -> [ConversionCandidate] {
        guard !kana.isEmpty else { return [] }
        var text = ComposingText()
        text.insertAtCursorPosition(kana, inputStyle: .direct)
        let result = converter.requestCandidates(text, options: options)
        var seen = Set<String>()
        var out: [ConversionCandidate] = []
        lastCandidates = [:]
        for c in result.mainResults where !c.text.isEmpty && seen.insert(c.text + "\u{0}\(c.correspondingCount)").inserted {
            out.append(ConversionCandidate(text: c.text, kanaCount: min(c.correspondingCount, kana.count)))
            lastCandidates[Self.key(c.text, min(c.correspondingCount, kana.count))] = c
        }
        out = rerank(out, kanaCount: kana.count)
        // The reading itself, in hiragana and katakana, is always available.
        for plain in [kana, RomajiComposer.katakana(kana)] where !out.contains(where: { $0.text == plain && $0.kanaCount == kana.count }) {
            out.append(ConversionCandidate(text: plain, kanaCount: kana.count))
        }
        // The candidate window shows text only, and a click comes back as text: one row per
        // text (the better-ranked coverage).
        var shown = Set<String>()
        return out.filter { shown.insert($0.text).inserted }
    }

    private static func key(_ text: String, _ kanaCount: Int) -> String { text + "\u{0}\(kanaCount)" }

    /// How much AzooKey's own order counts against the text model when reranking
    /// whole-reading candidates (log-probability per rank step). Tuned on sentences
    /// held out from the text model; nil disables reranking.
    public var rerankWeight: Double? = 1.0

    /// Reorders the candidates that cover the whole reading by text-model probability
    /// plus a prior for AzooKey's rank; partial (first-clause) candidates keep their order after them.
    private func rerank(_ candidates: [ConversionCandidate], kanaCount: Int) -> [ConversionCandidate] {
        Self.rerank(candidates, kanaCount: kanaCount, weight: rerankWeight)
    }

    /// The same reranking for any converter's candidates.
    static func rerank(_ candidates: [ConversionCandidate], kanaCount: Int, weight: Double?) -> [ConversionCandidate] {
        guard let weight, let model = JapaneseModel.text else { return candidates }
        let full = candidates.enumerated().filter { $0.element.kanaCount == kanaCount }
        let scored = full.map { (rank, c) in
            (c, model.logProbability(kana: c.text, partial: false) - weight * Double(rank))
        }
        let reordered = scored.sorted { $0.1 > $1.1 }.map(\.0)
        return reordered + candidates.filter { $0.kanaCount != kanaCount }
    }

    public func learn(_ candidate: ConversionCandidate, for kana: String) {
        guard let original = lastCandidates[Self.key(candidate.text, candidate.kanaCount)] else { return }
        converter.updateLearningData(original)
    }

    /// Writes learning data to disk (call when the input method is deactivated).
    public func save() {
        converter.sendToDicdataStore(.closeKeyboard)
    }
}

/// Converters a kanji reset threw away. A session made before the reset still holds its old one,
/// and saving that when it is replaced would write back the learning the reset deleted.
public final class DiscardedConverters {
    private struct Ref { weak var converter: (any JapaneseConverter)? }
    private var refs: [Ref] = []

    public init() {}

    public func insert(_ converter: (any JapaneseConverter)?) {
        refs.removeAll { $0.converter == nil }
        if let converter { refs.append(Ref(converter: converter)) }
    }

    public func contains(_ converter: any JapaneseConverter) -> Bool {
        refs.contains { $0.converter === converter }
    }
}
