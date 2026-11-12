import Foundation

/// The Settings screen's values as JSON, for `~/.config/matinee/settings.json`: the app writes every setting there and
/// applies the file when it changes, so the settings can be edited by hand or by an agent.
public enum SettingsFile {
    /// Max height for new videos; 0 is Best.
    public static let qualities = [0, 2160, 1440, 1080, 720, 480]

    private static let bools: [(key: String, defaultValue: Bool)] = [
        ("openglPlayback", false), ("dearrowTitles", true), ("dearrowThumbnails", true), ("showComments", false),
        ("recommendations", true), ("localModels", true),
    ]

    /// Free text: the Brave profile, and the subtitle and audio languages last picked in the player ("" is none).
    private static let strings = ["braveProfile", "subtitleLanguage", "audioLanguage"]

    /// Every setting with its current value (or default), pretty-printed with sorted keys.
    public static func json(from defaults: UserDefaults) -> Data {
        var o: [String: Any] = [
            "defaultQuality": defaults.integer(forKey: "defaultQuality"),
            "sponsorblock": Dictionary(uniqueKeysWithValues: SponsorBlock.categories.map {
                ($0.id, defaults.object(forKey: "sponsorblock.\($0.id)") as? Bool ?? $0.defaultOn)
            }),
        ]
        for key in strings { o[key] = defaults.string(forKey: key) ?? "" }
        for b in bools { o[b.key] = defaults.object(forKey: b.key) as? Bool ?? b.defaultValue }
        // Only plain values go in, so this can't fail.
        return try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Stores the settings `data` gives; settings it leaves out keep their value. Returns the keys that were skipped
    /// (unknown, or a value of the wrong type or out of range, e.g. "defaultQuality" or "sponsorblock.intro").
    /// Throws, changing nothing, when `data` isn't a JSON object.
    public static func apply(_ data: Data, to defaults: UserDefaults) throws -> [String] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var skipped: [String] = []
        for (key, value) in o {
            switch key {
            case "defaultQuality":
                if let n = number(value), !isBool(n), qualities.contains(n.intValue), n.doubleValue == Double(n.intValue) {
                    defaults.set(n.intValue, forKey: key)
                } else { skipped.append(key) }
            case _ where strings.contains(key):
                if let s = value as? String { defaults.set(s, forKey: key) } else { skipped.append(key) }
            case "sponsorblock":
                guard let inner = value as? [String: Any] else { skipped.append(key); continue }
                let ids = Set(SponsorBlock.categories.map(\.id))
                for (id, v) in inner {
                    if ids.contains(id), let b = bool(v) { defaults.set(b, forKey: "sponsorblock.\(id)") }
                    else { skipped.append("sponsorblock.\(id)") }
                }
            default:
                if bools.contains(where: { $0.key == key }), let b = bool(value) { defaults.set(b, forKey: key) }
                else { skipped.append(key) }
            }
        }
        return skipped.sorted()
    }

    private static func number(_ v: Any) -> NSNumber? { v as? NSNumber }
    /// JSON true/false, not a number that Foundation would also bridge to Bool.
    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
    private static func bool(_ v: Any) -> Bool? {
        guard let n = v as? NSNumber, isBool(n) else { return nil }
        return n.boolValue
    }
}
