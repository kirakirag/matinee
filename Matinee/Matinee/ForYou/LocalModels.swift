import CryptoKit
import Foundation
import MatineeKit
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// The two models of "Local AI ranking", downloaded once from Hugging Face into Application Support/Models:
/// multilingual-e5-large (titles and descriptions → vectors) and JevK5 (the judge). A model counts as present only
/// when every file has its full size and, for the weights, its SHA-256, so an interrupted download is never loaded;
/// the next download resumes the partial file.
@MainActor @Observable
final class LocalModels {
    enum State: Equatable { case absent, downloading(Double), ready, failed(String) }

    nonisolated struct Spec: Sendable {
        let repo: String
        let revision: String
        let files: [String]
        /// The folder name under Models.
        var folder: String { repo.replacingOccurrences(of: "/", with: "--") + "@" + revision.prefix(12) }
    }

    static let e5 = Spec(repo: "intfloat/multilingual-e5-large", revision: "3d7cfbdacd47fdda877c5cd8a79fbcc4f2a574f3",
                         files: ["config.json", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json",
                                 "model.safetensors"])
    static let judge = Spec(repo: "alibiserikbay/JevK5", revision: "c4f7fdb3aeab5582336406e78d3bef11bf98833d",
                            files: ["config.json", "tokenizer.json", "tokenizer_config.json", "generation_config.json",
                                    "model.safetensors"])

    /// Settings' "Local AI ranking"; on by default, and only with "Up next and For You" on.
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "localModels") as? Bool ?? true) && ForYouModel.isEnabled
    }

    private(set) var state: State = .absent
    private(set) var bytesOnDisk: Int64 = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Set by the app: For You refines once the models arrive.
    @ObservationIgnored var onReady: (() -> Void)?
    @ObservationIgnored let root: URL

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)) {
        self.root = root
        refresh()
    }

    func directory(_ spec: Spec) -> URL { root.appending(path: spec.folder, directoryHint: .isDirectory) }

    /// Downloads what's missing; a partial file carries on where it stopped.
    func download() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        let specs = [Self.e5, Self.judge], dirs = specs.map(directory)
        task = Task {
            do {
                var plans: [Int: [HubFile]] = [:]
                for (i, spec) in specs.enumerated() { plans[i] = try await HubFile.list(spec) }
                let total = plans.values.joined().reduce(Int64(0)) { $0 + $1.size }
                var done: Int64 = 0
                for (i, dir) in dirs.enumerated() {
                    for file in plans[i] ?? [] {
                        let before = done
                        try await file.fetch(into: dir) { got in
                            Task { @MainActor in
                                guard case .downloading = self.state else { return }
                                self.state = .downloading(Double(before + got) / Double(max(total, 1)))
                            }
                        }
                        done += file.size
                    }
                    if specs[i].repo == Self.judge.repo { try Self.declareTextModel(in: dir) }
                    try Data().write(to: dir.appending(path: ".complete"))
                }
                state = .ready
                onReady?()
            } catch is CancellationError {
                state = .absent
            } catch {
                state = Task.isCancelled ? .absent : .failed(error.localizedDescription)
            }
            task = nil
            bytesOnDisk = Self.size(of: root)
        }
    }

    /// Stops a download; what arrived stays for next time.
    func cancel() {
        task?.cancel()
        task = nil
        if case .downloading = state { state = .absent }
    }

    func delete() {
        cancel()
        try? FileManager.default.removeItem(at: root)
        refresh()
    }

    private func refresh() {
        let complete = [Self.e5, Self.judge].allSatisfy {
            FileManager.default.fileExists(atPath: directory($0).appending(path: ".complete").path)
        }
        state = complete ? .ready : .absent
        bytesOnDisk = Self.size(of: root)
    }

    /// JevK5's weights carry the multimodal wrapper's names (`model.language_model.…`), which MLX reads as `qwen3_5`
    /// (the same override the Python experiments used); its config says `qwen3_5_text`.
    nonisolated static func declareTextModel(in dir: URL) throws {
        let url = dir.appending(path: "config.json")
        guard var config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { return }
        config["model_type"] = "qwen3_5"
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]).write(to: url)
    }

    nonisolated static func size(of dir: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }
}

/// One file of a pinned Hugging Face revision: its size and, for large files, SHA-256.
nonisolated struct HubFile: Sendable {
    private static let chunk: Int64 = 64 << 20
    let spec: LocalModels.Spec
    let path: String
    let size: Int64
    let sha256: String?

    @concurrent static func list(_ spec: LocalModels.Spec) async throws -> [HubFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(spec.repo)/tree/\(spec.revision)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Entry: Decodable {
            struct LFS: Decodable { let oid: String; let size: Int64 }
            let path: String; let size: Int64; let lfs: LFS?
        }
        let entries = Dictionary(try JSONDecoder().decode([Entry].self, from: data).map { ($0.path, $0) }) { a, _ in a }
        return try spec.files.map { name in
            guard let e = entries[name] else { throw URLError(.fileDoesNotExist) }
            return HubFile(spec: spec, path: name, size: e.lfs?.size ?? e.size, sha256: e.lfs?.oid)
        }
    }

    /// Downloads to `<name>.partial` (resuming it), checks size and hash, then moves it into place.
    @concurrent func fetch(into dir: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let final = dir.appending(path: path), partial = dir.appending(path: path + ".partial")
        let fm = FileManager.default
        if let have = try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(have) == size {
            progress(size)
            return
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        if offset > size { try handle.truncate(atOffset: 0); offset = 0 }
        // 64 MB ranges: a quit loses at most one, and memory stays flat.
        let url = URL(string: "https://huggingface.co/\(spec.repo)/resolve/\(spec.revision)/\(path)")!
        while offset < size {
            try Task.checkCancellation()
            let end = min(offset + Self.chunk, size) - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 206 with the asked range; a 200 (Range ignored) only counts as the whole file from the start.
            let whole = status == 200 && offset == 0 && Int64(data.count) == size
            guard whole || (status == 206 && Int64(data.count) == end - offset + 1) else {
                throw URLError(.badServerResponse)
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            progress(offset)
        }
        try handle.close()
        guard offset == size else { throw URLError(.cannotDecodeContentData) }
        if let sha256, try await Self.digest(partial) != sha256 {
            try? fm.removeItem(at: partial)   // corrupt: start over next time
            throw URLError(.cannotDecodeContentData)
        }
        _ = try? fm.removeItem(at: final)
        try fm.moveItem(at: partial, to: final)
    }

    private static func digest(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 24), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

/// swift-transformers' tokenizer as MLX's: the adapter mlx-swift-lm's `#huggingFaceTokenizerLoader` macro expands to.
nonisolated struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        Bridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }

    private struct Bridge: MLXLMCommon.Tokenizer {
        let upstream: any Tokenizers.Tokenizer
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
        }
        func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
        func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
        var bosToken: String? { upstream.bosToken }
        var eosToken: String? { upstream.eosToken }
        var unknownToken: String? { upstream.unknownToken }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            do {
                return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
            } catch Tokenizers.TokenizerError.missingChatTemplate {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
        }
    }
}

/// multilingual-e5-large: mean of the last hidden states over the real tokens, L2-normalised, as sentence-transformers
/// computes it. Texts start with "passage: ". Loaded on first use and kept while the app runs.
actor E5Embedder {
    private let directory: URL
    private var container: EmbedderModelContainer?

    init(directory: URL) { self.directory = directory }

    func vectors(_ texts: [(id: String, text: String)]) async throws -> [String: [Float]] {
        if container == nil {
            container = try await EmbedderModelFactory.shared.loadContainer(from: directory,
                                                                             using: TransformersTokenizerLoader())
        }
        guard let container else { return [:] }
        var out: [String: [Float]] = [:]
        for start in stride(from: 0, to: texts.count, by: 32) {
            try Task.checkCancellation()
            let batch = Array(texts[start..<min(start + 32, texts.count)])
            let strings = batch.map(\.text)
            let vectors: [[Float]] = await container.perform { context in
                let pad = 1   // XLM-RoBERTa's <pad>
                let encoded = strings.map { text -> [Int] in
                    let ids = context.tokenizer.encode(text: text, addSpecialTokens: true)
                    return ids.count <= 512 ? ids : Array(ids.prefix(511)) + [ids.last!]   // keep </s>, as HF truncates
                }
                let length = encoded.map(\.count).max() ?? 1
                let ids = MLXArray(encoded.flatMap { $0 + Array(repeating: pad, count: length - $0.count) }.map(Int32.init),
                                   [encoded.count, length])
                let mask = MLXArray(encoded.flatMap { Array(repeating: Int32(1), count: $0.count)
                    + Array(repeating: Int32(0), count: length - $0.count) }, [encoded.count, length])
                let hidden = context.model(ids, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: ids),
                                           attentionMask: mask).hiddenStates!.asType(.float32)
                let m = mask.asType(.float32).expandedDimensions(axis: -1)
                let pooled = (hidden * m).sum(axis: 1) / m.sum(axis: 1)
                let normed = pooled / sqrt((pooled * pooled).sum(axis: -1, keepDims: true))
                eval(normed)
                return (0..<encoded.count).map { normed[$0].asArray(Float.self) }
            }
            for (item, v) in zip(batch, vectors) { out[item.id] = v }
        }
        return out
    }
}

/// JevK5, the judge: P(A: would watch) against B, as logit(A) − logit(B) where the answer starts. The profile, the
/// same for every candidate, runs once; each candidate continues from a copy of the caches after it. The model is
/// loaded per run and released after it (8 GB).
actor JevJudge {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func logits(profile: String, candidates: [(id: String, title: String, channel: String, seconds: Int?)])
        async throws -> [String: Double] {
        guard !candidates.isEmpty else { return [:] }
        let out = try await judge(profile: profile, candidates: candidates)
        Memory.clearCache()   // the model is gone with `judge`'s container; hand its buffers back
        return out
    }

    private func judge(profile: String, candidates: [(id: String, title: String, channel: String, seconds: Int?)])
        async throws -> [String: Double] {
        let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        let prompts = candidates.map { c in
            (c.id, JudgePrompt.prompt(profile: profile, candidate: (c.title, c.channel, c.seconds)))
        }
        let probes = ["Alpha", "Zulu"].map { JudgePrompt.prompt(profile: profile, candidate: ($0, "X", nil)) }
        return try await container.perform { context in
            let model = context.model, tokenizer = context.tokenizer
            guard let a = tokenizer.convertTokenToId("A"), let b = tokenizer.convertTokenToId("B") else {
                throw MLXLMCommon.TokenizerError.missingChatTemplate
            }
            let (p, q) = (tokenizer.encode(text: probes[0], addSpecialTokens: false),
                          tokenizer.encode(text: probes[1], addSpecialTokens: false))
            let prefix = Array(p.prefix(zip(p, q).prefix { $0 == $1 }.count))
            let cache = try model.newCache(parameters: nil)
            if !prefix.isEmpty { eval(model(Self.batch(prefix), cache: cache)); eval(cache) }
            var out: [String: Double] = [:]
            for (id, prompt) in prompts {
                try Task.checkCancellation()
                let full = tokenizer.encode(text: prompt, addSpecialTokens: false)
                let shared = !prefix.isEmpty && full.count > prefix.count && Array(full.prefix(prefix.count)) == prefix
                let logits = shared
                    ? model(Self.batch(Array(full.dropFirst(prefix.count))), cache: cache.map { $0.copy() })
                    : model(Self.batch(full), cache: try model.newCache(parameters: nil))
                let last = logits[0, logits.dim(1) - 1].asType(.float32)
                eval(last)
                out[id] = Double(last[a].item(Float.self) - last[b].item(Float.self))
            }
            return out
        }
    }

    private static func batch(_ tokens: [Int]) -> MLXArray {
        MLXArray(tokens.map(Int32.init), [1, tokens.count])
    }
}
