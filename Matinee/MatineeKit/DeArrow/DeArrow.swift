import CryptoKit
import Foundation

/// A community replacement title and/or thumbnail time for a video.
public struct Branding: Sendable, Equatable {
    public var title: String?
    public var thumbnailTime: Double?

    public init(title: String?, thumbnailTime: Double?) {
        self.title = title
        self.thumbnailTime = thumbnailTime
    }
}

public enum DeArrow {
    /// Decodes to nil instead of throwing, so one bad element doesn't sink its siblings.
    private struct Lossy<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: Decoder) { value = try? T(from: decoder) }
    }

    private struct Entry: Decodable {
        struct Title: Decodable {
            var title: String; var original: Bool; var votes: Int; var locked: Bool
            enum Keys: String, CodingKey { case title, original, votes, locked }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                title = try c.decode(String.self, forKey: .title)
                original = (try? c.decode(Bool.self, forKey: .original)) ?? false
                votes = (try? c.decode(Int.self, forKey: .votes)) ?? 0
                locked = (try? c.decode(Bool.self, forKey: .locked)) ?? false
            }
        }
        struct Thumbnail: Decodable {
            var timestamp: Double?; var original: Bool; var votes: Int; var locked: Bool
            enum Keys: String, CodingKey { case timestamp, original, votes, locked }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                timestamp = try? c.decode(Double.self, forKey: .timestamp)
                original = (try? c.decode(Bool.self, forKey: .original)) ?? false
                votes = (try? c.decode(Int.self, forKey: .votes)) ?? 0
                locked = (try? c.decode(Bool.self, forKey: .locked)) ?? false
            }
        }
        var titles: [Title]
        var thumbnails: [Thumbnail]
        var randomTime: Double?
        var videoDuration: Double?
        enum Keys: String, CodingKey { case titles, thumbnails, randomTime, videoDuration }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            titles = ((try? c.decode([Lossy<Title>].self, forKey: .titles)) ?? []).compactMap(\.value)
            thumbnails = ((try? c.decode([Lossy<Thumbnail>].self, forKey: .thumbnails)) ?? []).compactMap(\.value)
            randomTime = try? c.decode(Double.self, forKey: .randomTime)
            videoDuration = try? c.decode(Double.self, forKey: .videoDuration)
        }
    }

    /// First 4 lowercase hex characters of SHA-256(videoId), the k-anonymity prefix the API takes.
    public static func hashPrefix(_ videoId: String) -> String {
        // Only the first two bytes are needed; formatting all 32 with String(format:) was most of the cost.
        SHA256.hash(data: Data(videoId.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    public static func brandingURL(prefix: String) -> URL {
        URL(string: "https://sponsor.ajay.app/api/branding/\(prefix)")!
    }

    public static func thumbnailURL(videoId: String, time: Double) -> URL? {
        guard VideoID.isValid(videoId) else { return nil }
        return URL(string: "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=\(videoId)&time=\(time)")
    }

    /// Branding for every valid video id in a prefix response; ids with nothing usable are omitted.
    public static func parse(_ data: Data) throws -> [String: Branding] {
        let entries = try JSONDecoder().decode([String: Lossy<Entry>].self, from: data)
        var out: [String: Branding] = [:]
        for (id, lossy) in entries where VideoID.isValid(id) {
            guard let entry = lossy.value else { continue }
            // DeArrow ranks the list: only the top entry counts, and an original on top means no custom one
            let title = entry.titles.first.flatMap { !$0.original && ($0.locked || $0.votes >= 0) ? clean($0.title) : nil }
            let time = thumbnailTime(entry)
            if title != nil || time != nil { out[id] = Branding(title: title, thumbnailTime: time) }
        }
        return out
    }

    /// The top submission when trusted (none if it's the original). Without a trusted one, the frame at
    /// `randomTime × videoDuration`, as DeArrow's extension does; none when the duration is unknown.
    private static func thumbnailTime(_ entry: Entry) -> Double? {
        if let top = entry.thumbnails.first, top.locked || top.votes >= 0 {
            return top.original ? nil : top.timestamp
        }
        guard let fraction = entry.randomTime, (0...1).contains(fraction),
              let duration = entry.videoDuration, duration > 0 else { return nil }
        return fraction * duration
    }

    private static func clean(_ raw: String) -> String? {
        var s = Substring(raw)
        if s.hasPrefix(">") { s = s.dropFirst() }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(300))
        return String(String.UnicodeScalarView(capped.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
    }
}
