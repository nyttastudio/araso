import Foundation

/// Syllable-unigram model for Korean: enough to tell "안녕하세요" from the accidental
/// Hangul that English produces on a 2-set layout (e.g. "the" → "솓").
public struct KoreanModel: Sendable {
    public struct Score: Sendable {
        /// Average log-probability per keystroke.
        public let averageLogProbability: Double
        public let composition: HangulComposer.Result
    }

    private let tiers: [Character: Double]
    /// Words seen in Korean sentences (Data/korean_words.txt, Tatoeba): 나는, 무슨, 내가…
    private let words: Set<String>

    static let tier1LogP = -5.0
    static let tier2LogP = -6.5
    static let tier3LogP = -8.0
    static let unknownSyllableLogP = -11.0
    static let strayJamoLogP = -13.0
    /// Typing the first consonant of the next syllable is normal mid-word.
    static let pendingConsonantLogP = -3.5
    /// The same for a consonant that joined the syllable before as its final (갷 of 소개ㅎ),
    /// a little less sure: alr is 미국 on its way and also already (tuned on preview traces of
    /// the top 10,000 English and Korean words).
    static let pendingFinalPenalty = 1.0
    /// ㅋㅋ, ㅎㅎ, ㅠㅠ and friends.
    static let chatJamoLogP = -4.0
    static let chatJamo: Set<Character> = Set("ㅋㅎㅠㅜㄷㅇㄱㅅㅂㄴ")

    /// Where syllable probabilities come from.
    public enum Source: String, Sendable {
        /// The hand-curated frequency tiers in KoreanSyllables.swift.
        case tiers
        /// Counts from Korean sentences (Data/korean_syllables.txt, Tatoeba, CC-BY 2.0 FR).
        case corpus
        /// Whichever of the two rates a syllable higher.
        case max
    }

    public init(source: Source = .max) {
        var map: [Character: Double] = [:]
        if source != .corpus {
            for (syllables, logP) in [(KoreanSyllables.tier3, Self.tier3LogP),
                                      (KoreanSyllables.tier2, Self.tier2LogP),
                                      (KoreanSyllables.tier1, Self.tier1LogP)] {
                for s in syllables where ("가"..."힣").contains(s) {
                    map[s] = logP // later (more frequent) tiers overwrite earlier ones
                }
            }
        }
        if source != .tiers, let counts = Self.corpusCounts() {
            let total = Double(counts.values.reduce(0, +))
            let smoothing = 0.5, possible = 11172.0
            for (s, n) in counts {
                let logP = log((Double(n) + smoothing) / (total + smoothing * possible))
                map[s] = Swift.max(map[s] ?? -.infinity, logP)
            }
        }
        tiers = map
        words = Self.corpusWords
    }

    /// A word that occurs in real Korean text (the composed Hangul, not the keys).
    public func isKnownWord(_ hangul: String) -> Bool { words.contains(hangul) }

    /// A word in the wider vocabulary (loanwords like 월드, 서버; 혜택), for English + Korean splits
    /// and the heuristic's Korean word floor.
    public func isVocabularyWord(_ hangul: String) -> Bool {
        words.contains(hangul) || Self.vocabulary.contains(hangul) || Self.loanwords.contains(hangul)
    }

    /// Developer and product words the subtitles (2018) have fewer than `commonCount` times or not at
    /// all: 깃허브, 리액트, 노션, 도커. The counterpart of `EnglishModel.commonWords`, for the word
    /// floor and the splits only (not `knowsSyllable`, which `EU정책` and `RJ이` rely on). A word
    /// goes in only when its keys spell no English word (`aor` 맥, `shtus` 노션; `ahr` 목 is left out
    /// as an everyday word in its own right), checked by running en_50k.txt and eval.tsv through
    /// `araso-cli --decide` before and after (AGENTS.md, wrong-split checks).
    static let loanwords: Set<String> = Set("""
    깃허브 깃랩 깃 커밋 리베이스 리포 레포 이슈 린트 포맷 빌드 릴리스 롤백 핫픽스
    리액트 넥스트 뷰 스벨트 앵귤러 노드 타입스크립트 자바스크립트 파이썬 자바 스위프트 코틀린 러스트 고랭 닷넷 플러터 레일스 장고
    도커 쿠버네티스 람다 테라폼 앤서블 깃헙액션 파이프라인 로깅 크론
    노션 슬랙 피그마 지라 컨플루언스 줌 디스코드 트렐로 아사나 리니어 옵시디언 에버노트 드롭박스 구글독스 캘린더 지메일
    챗지피티 클로드 제미나이 코파일럿 엘엘엠 프롬프트 토큰 임베딩 파인튜닝 추론 데이터셋
    맥북 맥 아이맥 아이폰 에어팟 애플워치 삼성 윈도우 리눅스 우분투 안드로이드 크롬 사파리 파이어폭스 브라우저
    인스타 스레드 넷플릭스 스포티파이 카톡 카카오톡 텔레그램 왓츠앱 페북 링크드인
    리팩터링 리팩토링 디버깅 디버그 컴파일 컴파일러 프레임워크 라이브러리 모듈 함수 변수 객체 배열 문자열 인터페이스 제네릭 클로저 콜백 비동기 스레드 큐 스택 힙 해시 쿼리 인덱스
    트랜잭션 스키마 마이그레이션
    엔드포인트 라우터 미들웨어 핸들러 컨트롤러 리포지토리 엔티티 디비 데이터베이스 포스트그레스 마이에스큐엘 레디스 몽고 엘라스틱
    프론트 프론트엔드 백엔드 풀스택 데브옵스 인프라 클라이언트 웹 앱 도메인 호스팅 배포판 런타임 콘솔 셸 쉘 스크립트 환경변수 설정값
    회원가입 토글 모달 팝업 드롭다운 탭 사이드바 네비게이션 툴바 아이콘 폰트 다크모드 반응형 레이아웃 컴포넌트 프롭스 훅 렌더링
    유닛테스트 통합테스트 스텁 커버리지 린터 포매터 프리티어 이에스린트 타입체크 씨아이 씨디 워크플로 러너
    버그 익셉션 크래시 타임아웃 레이턴시 스루풋 누수 최적화 프로파일링 벤치마크
    마크다운 리드미 위키 문서화 스니펫 템플릿 보일러플레이트 스캐폴딩 제너레이터
    메신저 알림 푸시알림 위젯 숏컷 단축키 클립보드 스크린샷
    블루투스 유에스비 충전기 디스플레이 트랙패드 웹캠 이어폰
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// A word the subtitles have fewer than `commonCount` times (촉매, twice): for the heuristic's
    /// Korean word floor only. The tail holds dialect and typos too (어뗘, 쓔벌, 꺼이), so it
    /// stays out of the splits and of `knowsSyllable`, which `EU정책` and `RJ이` rely on.
    public func isRareVocabularyWord(_ hangul: String) -> Bool { Self.rareVocabulary.contains(hangul) }

    /// A noun the lists only have with a case particle (혜택 from 혜택을, 혜택으로): they
    /// count words with their particles, so a bare noun can be missing from both.
    public func isKnownStem(_ hangul: String) -> Bool { Self.stems.contains(hangul) }

    /// Where `korean_vocabulary.txt` stops being `vocabulary`: the old 50k list's last count.
    static let commonCount = 10

    /// Case particles, by what the noun must end in: a final consonant (을), none (를), or either.
    private static let particles: [(String, Bool?)] = [
        ("을", true), ("은", true), ("이", true), ("과", true), ("으로", true),
        ("를", false), ("는", false), ("가", false), ("와", false),
        ("에", nil), ("의", nil), ("도", nil), ("에서", nil), ("만", nil),
    ]

    private static let stems: Set<String> = {
        var stems = Set<String>()
        for word in corpusWords.union(vocabulary).union(rareVocabulary) {
            for (particle, final) in particles where word.hasSuffix(particle) {
                let stem = word.dropLast(particle.count)
                guard stem.count >= 2, let last = stem.last?.unicodeScalars.first?.value,
                      (0xAC00...0xD7A3).contains(last) else { continue }
                let hasFinal = (last - 0xAC00) % 28 != 0
                if final == nil || final == hasFinal { stems.insert(String(stem)) }
            }
        }
        return stems
    }()

    private static let vocabulary = Set(vocabularyCounts.filter { $0.count >= commonCount }.map(\.word))
    private static let rareVocabulary = Set(vocabularyCounts.filter { $0.count < commonCount }.map(\.word))

    private static let vocabularyCounts: [(word: String, count: Int)] = {
        guard let url = Resources.koreanVocabulary, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            let parts = $0.split(separator: "\t")
            guard parts.count == 2, let n = Int(parts[1]) else { return nil }
            return (String(parts[0]), n)
        }
    }()

    private static let corpusWords: Set<String> = {
        guard let url = Resources.koreanWords, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { $0.split(separator: "\t").first.map(String.init) })
    }()

    private static func corpusCounts() -> [Character: Int]? {
        guard let url = Resources.koreanSyllables, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var counts: [Character: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t")
            if parts.count == 2, let s = parts[0].first, let n = Int(parts[1]) { counts[s] = n }
        }
        return counts
    }

    public func syllableLogProbability(_ syllable: Character) -> Double {
        tiers[syllable] ?? Self.unknownSyllableLogP
    }

    /// A syllable seen at all: in the tiers, the corpus or a word of the lists, however rarely
    /// (삐, 쪄, 뾰, 쭈 are; 뗘, 쎠, 쓔 aren't). Rarer than `unknownSyllableLogP` still means
    /// someone typed it.
    public func knowsSyllable(_ syllable: Character) -> Bool {
        tiers[syllable] != nil || Self.listSyllables.contains(syllable)
    }

    /// `knowsSyllable`, or in a word the subtitles have only a few times (왑 of 나왑, 챕 of 챕터들,
    /// 탭): for 3-set's digit and symbol keys, which go on with the word only into a syllable
    /// someone types. A key there can only add a final or a vowel, never make 뗘, so the tail's
    /// dialect and typos matter less than its loanwords.
    public func knowsSyllableIncludingRare(_ syllable: Character) -> Bool {
        knowsSyllable(syllable) || Self.rareListSyllables.contains(syllable)
    }

    private static let rareListSyllables: Set<Character> = {
        var set = Set<Character>()
        for word in rareVocabulary { set.formUnion(word) }
        return set
    }()

    private static let listSyllables: Set<Character> = {
        var set = Set<Character>()
        for word in vocabulary { set.formUnion(word) }
        for word in corpusWords { set.formUnion(word) }
        return set
    }()

    /// - Parameter partial: the token is still being typed, so a trailing lone
    ///   consonant is expected rather than penalized.
    public func score(keys: String, partial: Bool = false) -> Score? {
        guard let composition = HangulComposer.compose(keys: keys), !keys.isEmpty else { return nil }
        var total = logProbability(composition, partial: partial)
        // The consonant typed last may have joined the syllable before as its final (개 + ㅎ
        // shows 갷) while it is the next syllable's first (소개하는): score that reading too. Only
        // on 2-set: 3-set has its own keys for finals.
        if partial, KoreanLayout.current == .dubeolsik, !composition.isChat, let last = keys.last, DubeolsikLayout.jamo(for: last).map(Jamo.isConsonant) == true,
           case .syllable = composition.units.last,
           let before = HangulComposer.compose(keys: String(keys.dropLast())), before.units.count == composition.units.count,
           case .syllable = before.units.last {
            total = max(total, logProbability(before, partial: false) + Self.pendingConsonantLogP - Self.pendingFinalPenalty)
        }
        return Score(averageLogProbability: total / Double(keys.count), composition: composition)
    }

    private func logProbability(_ composition: HangulComposer.Result, partial: Bool) -> Double {
        let units = composition.units
        let allChat = composition.isChat
        var total = 0.0
        for (i, unit) in units.enumerated() {
            switch unit {
            case .syllable(let s):
                total += syllableLogProbability(s)
            case .jamo(let j):
                if allChat {
                    total += Self.chatJamoLogP
                } else if partial && i == units.count - 1 && Jamo.isConsonant(j) {
                    total += Self.pendingConsonantLogP
                } else {
                    total += Self.strayJamoLogP
                }
            }
        }
        return total
    }
}

extension HangulComposer.Result {
    /// ㅋㅋ, ㅠㅠ, ㅜㅜ: two or more of the jamo typed on their own in chat. Korean as it is, and
    /// already complete: they don't go on to make syllables.
    /// On 3-set only the same jamo again (ㅋㅋ, ㅎㅎ): its consonants sit on the right hand's
    /// letters, so a mix of them is English as often as not (jun is ㅇㄷㅅ, uhh ㄷㄴㄴ).
    public var isChat: Bool {
        units.count >= 2 && units.allSatisfy {
            if case .jamo(let j) = $0 { return KoreanModel.chatJamo.contains(j) }
            return false
        } && (KoreanLayout.current == .dubeolsik || Set(units.map(\.character)).count == 1)
    }

    /// Two or more loose consonants, or ㅜ/ㅠ: what chat abbreviates to (ㅁㅊ, ㅈㅅ, ㄹㅇ, ㅜㅜ).
    /// A reading worth switching to, though only the common ones (`isChat`) score as Korean.
    public var isJamoAbbreviation: Bool {
        units.count >= 2 && units.allSatisfy {
            if case .jamo(let j) = $0 { return Jamo.isConsonant(j) || j == "ㅜ" || j == "ㅠ" }
            return false
        }
    }
}
