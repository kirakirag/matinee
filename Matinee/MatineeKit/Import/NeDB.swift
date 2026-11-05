import Foundation

/// Reads NeDB's append-only files (FreeTube's `.db`): one JSON document per line, later lines
/// replace earlier ones with the same `_id`, and `{"$$deleted": true}` removes it.
public enum NeDB {
    /// Live records in first-seen order, plus the number of lines that weren't valid JSON objects.
    public static func load(_ data: Data) -> (records: [[String: Any]], badLines: Int) {
        var latest: [String: [String: Any]] = [:]
        var order: [String] = []
        // Every id in `order`; a deleted one stays, so a re-added record keeps its first place.
        var seen: Set<String> = []
        var bad = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = obj["_id"] as? String else { bad += 1; continue }
            if obj["$$deleted"] as? Bool == true {
                latest[id] = nil
                continue
            }
            if seen.insert(id).inserted { order.append(id) }
            latest[id] = obj
        }
        return (order.compactMap { latest[$0] }, bad)
    }
}
