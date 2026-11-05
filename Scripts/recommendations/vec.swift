import NaturalLanguage
import Foundation
// Same as TitleSimilarity: per-script model, mean of token vectors. Writes ids.tsv (id, script, row) and vectors.f32.
func script(of title: String) -> NLScript? {
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
var models: [NLScript: NLContextualEmbedding] = [:]
func model(_ s: NLScript) -> NLContextualEmbedding? {
    if let m = models[s] { return m }
    guard let m = NLContextualEmbedding(script: s), m.hasAvailableAssets, (try? m.load()) != nil else { return nil }
    models[s] = m; return m
}
let lines = try! String(contentsOfFile: "titles.tsv", encoding: .utf8).split(separator: "\n")
var ids = "", data = Data(), row = 0
for line in lines {
    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { continue }
    let id = String(parts[0]), title = String(parts[1])
    guard let s = script(of: title), let m = model(s), let r = try? m.embeddingResult(for: title, language: nil) else { continue }
    var sum = [Double](repeating: 0, count: 512), n = 0.0
    r.enumerateTokenVectors(in: title.startIndex..<title.endIndex) { v, _ in for i in 0..<min(v.count, 512) { sum[i] += v[i] }; n += 1; return true }
    guard n > 0 else { continue }
    var f = sum.map { Float($0 / n) }
    data.append(Data(bytes: &f, count: f.count * 4))
    ids += "\(id)\t\(s.rawValue)\t\(row)\n"; row += 1
}
try! ids.write(toFile: "ids.tsv", atomically: true, encoding: .utf8)
try! data.write(to: URL(filePath: "vectors.f32"))
print("vectors", row, "scripts", models.keys.map(\.rawValue).sorted())
