import AppKit
import MatineeKit
import MLXLMCommon

/// `-modelselftest YES`: downloads the local models if needed, then checks them against the Python reference in
/// ModelSelfTest.json (Scripts/recommendations/selftest_reference.py): e5's vectors by cosine, JevK5's verdicts on 40
/// candidates by largest difference, the judge's time, and the tokenizer's tokens. Prints `MODELSELFTEST {...}`, quits.
enum ModelSelfTest {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "modelselftest") }

    private struct Reference: Decodable {
        struct Text: Decodable { let text: String; let vector: [Float] }
        struct Recent: Decodable { let title: String; let channel: String; let watched: Double? }
        struct Candidate: Decodable { let id: String; let title: String; let channel: String; let seconds: Int?; let logit: Double }
        let e5: [Text], subscriptions: [String], recent: [Recent], dismissed: [String], profile: String
        let candidates: [Candidate]
        let firstPromptTokens: [Int]
    }

    static func run(_ models: LocalModels) async {
        var line: [String: Any] = [:]
        do {
            if models.state != .ready {
                models.download()
                var last = -1
                while true {
                    switch models.state {
                    case .ready: break
                    case .downloading(let f):
                        if Int(f * 100) != last { last = Int(f * 100); print("MODELSELFTEST downloading \(last)%"); fflush(stdout) }
                        try await Task.sleep(for: .seconds(1))
                        continue
                    case .failed(let e): throw NSError(domain: "download", code: 1, userInfo: [NSLocalizedDescriptionKey: e])
                    case .absent: throw CancellationError()
                    }
                    break
                }
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let ref = try decoder.decode(Reference.self, from: Data(contentsOf: Bundle.main.url(forResource: "ModelSelfTest",
                                                                                               withExtension: "json")!))
            let profile = JudgePrompt.profile(subscriptions: ref.subscriptions,
                                              recent: ref.recent.map { ($0.title, $0.channel, $0.watched) }, dismissed: ref.dismissed)
            line["profile_matches"] = profile == ref.profile

            let embedder = E5Embedder(directory: models.directory(LocalModels.e5))
            var start = ContinuousClock.now
            let vectors = try await embedder.vectors(ref.e5.enumerated().map { ("\($0.offset)", $0.element.text) })
            line["e5_seconds"] = (ContinuousClock.now - start) / .seconds(1)
            line["e5_cos"] = ref.e5.enumerated().map { i, t in
                zip(vectors["\(i)"] ?? [], t.vector).reduce(0) { $0 + Double($1.0) * Double($1.1) }
            }
            line["e5_dimension"] = vectors["0"]?.count ?? 0

            let tokenizer = try await TransformersTokenizerLoader().load(from: models.directory(LocalModels.judge))
            let first = ref.candidates[0]
            line["tokens_match"] = tokenizer.encode(text: JudgePrompt.prompt(profile: profile, candidate: (first.title, first.channel, first.seconds)),
                                                    addSpecialTokens: false) == ref.firstPromptTokens

            let judge = JevJudge(directory: models.directory(LocalModels.judge))
            start = ContinuousClock.now
            let logits = try await judge.logits(profile: profile, candidates: ref.candidates.map { ($0.id, $0.title, $0.channel, $0.seconds) })
            line["judge_seconds"] = (ContinuousClock.now - start) / .seconds(1)
            line["judge_maxdiff"] = ref.candidates.map { abs((logits[$0.id] ?? .infinity) - $0.logit) }.max() ?? .infinity
            let swiftOrder = ref.candidates.sorted { logits[$0.id]! > logits[$1.id]! }.map(\.id)
            let pythonOrder = ref.candidates.sorted { $0.logit > $1.logit }.map(\.id)
            line["judge_top10_shared"] = Set(swiftOrder.prefix(10)).intersection(pythonOrder.prefix(10)).count
            // Python's 10th-best verdict: a difference within 0.25 of it is bf16 rounding, not disagreement.
            line["judge_10th_logit_py"] = ref.candidates.map(\.logit).sorted(by: >)[9]
            line["judge_top10_differs"] = Set(swiftOrder.prefix(10)).symmetricDifference(pythonOrder.prefix(10)).sorted().map { id in
                "\(id) swift \(logits[id]!) python \(ref.candidates.first { $0.id == id }!.logit)"
            }
            start = ContinuousClock.now
            _ = try await judge.logits(profile: profile, candidates: ref.candidates.map { ($0.id, $0.title, $0.channel, $0.seconds) })
            line["judge_seconds_warm"] = (ContinuousClock.now - start) / .seconds(1)
        } catch {
            line["error"] = "\(error)"
        }
        let json = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        print("MODELSELFTEST \(json ?? "{}")")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
