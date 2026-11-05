#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// How much each candidate's title is like the titles you watched, with Apple's on-device contextual embedding (no
/// download, nothing leaves the Mac). A title's vector is the mean of its token vectors; `VectorSimilarity` does the
/// rest (centring, 3 best matches), and the z-score is taken across the candidates of every script together.
/// Each script has its own model (Latin, Korean, Chinese, Japanese…), so titles are only compared within a script.
public actor TitleSimilarity {
    /// Whether the Latin model, which most titles use, is on this Mac.
    public static var isAvailable: Bool { NLContextualEmbedding(script: .latin)?.hasAvailableAssets ?? false }

    private var models: [NLScript: NLContextualEmbedding] = [:]
    private var unavailable: Set<NLScript> = []
    /// By video ID: a title's model and its vector; titles don't change.
    private var vectors: [String: (script: NLScript, vector: [Double])] = [:]
    /// Where vectors are kept across launches; new ones are saved after each `affinity`.
    private let store: Store?
    private var unsaved: [(id: String, script: String, vector: [Float])] = []

    public init(store: Store? = nil) {
        self.store = store
    }

    /// z-scores by candidate ID; candidates in a script the history has no title in are left out.
    /// With `disliked` titles ("Not interested"), a candidate's z-score of similarity to them is subtracted, so
    /// videos like what was dismissed fall, not only the dismissed ones.
    public func affinity(history: [(id: String, title: String)], candidates: [(id: String, title: String)],
                         disliked: [(id: String, title: String)] = []) -> [String: Double] {
        loadStored((history + candidates + disliked).map(\.id))
        defer { saveNew() }
        let h = history.compactMap { item in vector(item.id, item.title).map { (item.id, $0) } }
        let d = disliked.compactMap { item in vector(item.id, item.title).map { (item.id, $0) } }
        let c = candidates.compactMap { item in vector(item.id, item.title).map { (item.id, $0) } }
        var liked: [String: Double] = [:], unliked: [String: Double] = [:]
        for script in Set(c.map(\.1.script)) {
            let raw = VectorSimilarity.scores(history: h.filter { $0.1.script == script }.map(\.1.vector),
                                              candidates: c.filter { $0.1.script == script }.map { ($0.0, $0.1.vector) },
                                              disliked: d.filter { $0.1.script == script }.map(\.1.vector))
            liked.merge(raw.liked) { $1 }
            unliked.merge(raw.disliked) { $1 }
        }
        return VectorSimilarity.combine((liked, unliked))
    }

    private func vector(_ id: String, _ title: String) -> (script: NLScript, vector: [Double])? {
        if let cached = vectors[id] { return cached }
        guard !title.isEmpty, let script = Self.script(of: title), let model = model(for: script),
              let result = try? model.embeddingResult(for: title, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0.0
        result.enumerateTokenVectors(in: title.startIndex..<title.endIndex) { v, _ in
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let entry = (script, sum.map { $0 / count })
        vectors[id] = entry
        unsaved.append((id, script.rawValue, entry.1.map(Float.init)))
        return entry
    }

    /// Reads the stored vectors of IDs not in memory yet, in one go.
    private func loadStored(_ ids: [String]) {
        guard let store else { return }
        let missing = Array(Set(ids.filter { vectors[$0] == nil }))
        guard !missing.isEmpty, let stored = try? store.titleVectors(ids: missing) else { return }
        for (id, v) in stored { vectors[id] = (NLScript(rawValue: v.script), v.vector.map(Double.init)) }
    }

    private func saveNew() {
        guard let store, !unsaved.isEmpty else { return }
        try? store.saveTitleVectors(unsaved, at: .now)
        unsaved = []
    }

    private func model(for script: NLScript) -> NLContextualEmbedding? {
        if let m = models[script] { return m }
        guard !unavailable.contains(script), let m = NLContextualEmbedding(script: script), m.hasAvailableAssets,
              (try? m.load()) != nil else {
            unavailable.insert(script)
            return nil
        }
        models[script] = m
        return m
    }

    /// The title's dominant script: Korean, Japanese and Chinese characters win over Latin (titles mix them).
    static func script(of title: String) -> NLScript? {
        var latin = 0, hangul = 0, kana = 0, han = 0, cyrillic = 0
        for u in title.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x3040...0x30FF: kana += 1
            case 0x4E00...0x9FFF: han += 1
            case 0x400...0x4FF: cyrillic += 1
            default: break
            }
        }
        if hangul > 0, hangul * 2 >= latin { return .korean }
        if kana > 0, (kana + han) * 2 >= latin { return .japanese }
        if han > 0, han * 2 >= latin { return .simplifiedChinese }
        if cyrillic > latin { return .cyrillic }
        return latin > 0 ? .latin : nil
    }
}
#endif
