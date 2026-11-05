import Foundation

/// YouTube search filters, encoded as the `sp` query value (a tiny protobuf, per YouTube.js).
public struct SearchFilter: Sendable, Equatable {
    public enum Sort: Int, CaseIterable, Sendable {
        case relevance = 0, rating, uploadDate, viewCount
        public var title: String {
            switch self {
            case .relevance: "Relevance"
            case .rating: "Rating"
            case .uploadDate: "Upload date"
            case .viewCount: "View count"
            }
        }
    }

    public enum UploadDate: Int, CaseIterable, Sendable {
        case any = 0, hour, today, week, month, year
        public var title: String {
            switch self {
            case .any: "Any time"
            case .hour: "Last hour"
            case .today: "Today"
            case .week: "This week"
            case .month: "This month"
            case .year: "This year"
            }
        }
    }

    public enum Kind: Int, CaseIterable, Sendable {
        case any = 0, video, channel, playlist, movie
        public var title: String {
            switch self {
            case .any: "Any type"
            case .video: "Video"
            case .channel: "Channel"
            case .playlist: "Playlist"
            case .movie: "Movie"
            }
        }
    }

    public enum Length: Int, CaseIterable, Sendable {
        case any = 0, short, long, medium
        public var title: String {
            switch self {
            case .any: "Any length"
            case .short: "Under 4 minutes"
            case .long: "Over 20 minutes"
            case .medium: "4–20 minutes"
            }
        }
    }

    public var sort: Sort
    public var date: UploadDate
    public var type: Kind
    public var duration: Length

    public init(sort: Sort = .relevance, date: UploadDate = .any, type: Kind = .any, duration: Length = .any) {
        self.sort = sort
        self.date = date
        self.type = type
        self.duration = duration
    }

    /// Base64 protobuf for the `sp` parameter, or nil when every filter is default.
    public var sp: String? {
        var inner: [UInt8] = []
        if date != .any { inner += [0x08, UInt8(date.rawValue)] }
        if type != .any { inner += [0x10, UInt8(type.rawValue)] }
        if duration != .any { inner += [0x18, UInt8(duration.rawValue)] }
        var bytes: [UInt8] = []
        if sort != .relevance { bytes += [0x08, UInt8(sort.rawValue)] }
        if !inner.isEmpty { bytes += [0x12, UInt8(inner.count)] + inner }
        return bytes.isEmpty ? nil : Data(bytes).base64EncodedString()
    }
}

extension CaseIterable where Self: Equatable, AllCases: BidirectionalCollection, AllCases.Index == Int {
    /// The next case (`step` 1) or the previous one (-1), wrapping around: ⌥1–⌥4 step through a search filter.
    public func cycled(by step: Int) -> Self {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[((i + step) % all.count + all.count) % all.count]
    }
}
