/// YouTube video IDs: exactly 11 of `A–Z a–z 0–9 _ -`. Anything else never reaches yt-dlp or a URL.
public enum VideoID {
    public static func isValid(_ s: String) -> Bool { IDChars.matches(s, length: 11...11) }
}

/// YouTube playlist IDs: 12–64 of `A–Z a–z 0–9 _ -`.
public enum PlaylistID {
    public static func isValid(_ s: String) -> Bool { IDChars.matches(s, length: 12...64) }
}

/// YouTube channel handles: `@` followed by 3–30 of `A–Z a–z 0–9 . _ -`.
public enum ChannelHandle {
    public static func isValid(_ s: String) -> Bool { IDChars.matches(s, prefix: "@", length: 3...30, dot: true) }
}

/// YouTube channel IDs: `UC` followed by 22 of `A–Z a–z 0–9 _ -`.
public enum ChannelID {
    public static func isValid(_ s: String) -> Bool { IDChars.matches(s, prefix: "UC", length: 22...22) }
}

/// A byte scan instead of a `Regex` literal: a literal is rebuilt on every call (~45 µs each, measured on Linux),
/// and these checks run per row (DeArrow responses, thumbnail URLs, listings, the ⌘K filter's rows).
private enum IDChars {
    static func matches(_ s: String, prefix: String = "", length: ClosedRange<Int>, dot: Bool = false) -> Bool {
        guard s.utf8.starts(with: prefix.utf8) else { return false }
        var n = 0
        for b in s.utf8.dropFirst(prefix.utf8.count) {
            n += 1
            guard n <= length.upperBound else { return false }
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"): continue
            case UInt8(ascii: "."): if !dot { return false }
            default: return false
            }
        }
        return length.contains(n)
    }
}
