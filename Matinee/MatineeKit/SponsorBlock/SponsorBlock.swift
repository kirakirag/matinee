import Foundation

/// One SponsorBlock skip segment, in seconds.
public struct SponsorSegment: Codable, Sendable, Equatable {
    public let category: String
    public let start: Double
    public let end: Double
    public let uuid: String

    public init(category: String, start: Double, end: Double, uuid: String) {
        self.category = category
        self.start = start
        self.end = end
        self.uuid = uuid
    }
}

/// SponsorBlock's skip-segments API (https://sponsor.ajay.app), queried by hash prefix like DeArrow.
public enum SponsorBlock {
    public static let categories: [(id: String, title: String, defaultOn: Bool)] = [
        ("sponsor", "Sponsor", true),
        ("selfpromo", "Self-promotion", true),
        ("interaction", "Interaction reminder", false),
        ("intro", "Intro", false),
        ("outro", "Outro", false),
        ("preview", "Preview/recap", false),
        ("music_offtopic", "Non-music section", false),
        ("filler", "Filler", false),
    ]

    /// Asks for every category: without `categories` the server returns sponsor segments only
    /// (SponsorBlockServer `parseSkipSegments`), and filtering happens at use so Settings changes need no refetch.
    public static func skipSegmentsURL(prefix: String) -> URL {
        let list = "[" + categories.map { "\"\($0.id)\"" }.joined(separator: ",") + "]"
        var parts = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        parts.queryItems = [URLQueryItem(name: "categories", value: list)]
        return parts.url!
    }

    /// The video's skip segments (actionType "skip", start < end) from a hash-prefix response, which lists every
    /// video sharing the prefix. Malformed entries are dropped; a body that isn't a JSON array throws.
    public static func parse(_ data: Data, videoId: String) throws -> [SponsorSegment] {
        try JSONDecoder().decode([Lossy<Video>].self, from: data)
            .compactMap(\.value)
            .filter { $0.videoID == videoId }
            .flatMap { $0.segments.compactMap(\.value) }
            .compactMap { s in
                guard s.actionType == "skip", s.segment.count == 2, s.segment[0] < s.segment[1] else { return nil }
                return SponsorSegment(category: s.category, start: s.segment[0], end: s.segment[1], uuid: s.UUID)
            }
    }

    /// Categories switched on in Settings (`sponsorblock.<id>`), each defaulting to its `defaultOn`.
    public static func enabledCategories(_ defaults: UserDefaults) -> Set<String> {
        Set(categories.filter { defaults.object(forKey: "sponsorblock.\($0.id)") as? Bool ?? $0.defaultOn }.map(\.id))
    }

    private struct Video: Decodable {
        let videoID: String
        let segments: [Lossy<Segment>]
    }

    private struct Segment: Decodable {
        let category: String
        let actionType: String
        let segment: [Double]
        let UUID: String
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
    }
}
