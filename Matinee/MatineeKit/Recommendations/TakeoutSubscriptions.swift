import Foundation

/// Reads the subscriptions from a Google Takeout export (YouTube and YouTube Music → subscriptions →
/// subscriptions.csv): Channel Id, Channel Url, Channel Title. The header is in the account's language, so rows are
/// recognised by a valid channel ID in the first column rather than by the header.
public enum TakeoutSubscriptions {
    public struct NotTakeout: Error {}

    public static func parse(_ data: Data) throws -> [Channel] {
        guard var text = String(data: data, encoding: .utf8) else { throw NotTakeout() }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = records(text).filter { $0 != [""] }
        guard !rows.isEmpty, rows.allSatisfy({ $0.count >= 3 }) else { throw NotTakeout() }
        var seen: Set<String> = []
        return rows.compactMap { row in
            let id = row[0].trimmingCharacters(in: .whitespaces)
            guard ChannelID.isValid(id), seen.insert(id).inserted else { return nil }
            let name = row[2].trimmingCharacters(in: .whitespaces)
            return Channel(id: id, name: name.isEmpty ? id : name, thumbnailURL: nil, subscribedAt: .now)
        }
    }

    /// RFC 4180 records: fields split on commas, quoted fields may hold commas, line breaks and doubled quotes.
    private static func records(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = text.makeIterator()
        var pending = chars.next()
        while let c = pending {
            pending = chars.next()
            if quoted {
                if c == "\"" {
                    if pending == "\"" { field.append("\""); pending = chars.next() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
