import Foundation

/// YouTube's json3 captions as plain timed lines, written out as SubRip for mpv.
///
/// YouTube's own WebVTT can't be handed over as it is: an auto-generated track repeats every line in the next cue
/// (its two-line roll-up), which a player shows stacked twice, and an uploaded one can carry each cue once per
/// text style.
public enum SubtitleCues {
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The cues in time order. `rollUp` (an auto-generated track): each line stays only until the next one starts,
    /// since their durations overlap for the roll-up. Nil when `data` isn't json3.
    public static func parse(json3 data: Data, rollUp: Bool) -> [Cue]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { return nil }
        var cues: [Cue] = []
        for event in events {
            // An appended event only breaks the roll-up's line.
            guard event["aAppend"] == nil, let segs = event["segs"] as? [[String: Any]],
                  let start = (event["tStartMs"] as? NSNumber)?.doubleValue else { continue }
            let text = clean(segs.compactMap { $0["utf8"] as? String }.joined())
            guard !text.isEmpty else { continue }
            let duration = (event["dDurationMs"] as? NSNumber)?.doubleValue ?? 0
            let cue = Cue(start: start / 1000, end: (start + max(duration, 0)) / 1000, text: text)
            // The same cue once per style (e.g. the text and its outline).
            if let last = cues.last, last.start == cue.start, last.text == cue.text { continue }
            cues.append(cue)
        }
        cues.sort { $0.start < $1.start }   // stable, and almost always already in order
        if rollUp {
            for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start { cues[i].end = cues[i + 1].start }
        }
        return cues.filter { $0.end > $0.start }
    }

    /// Lines trimmed, empty ones dropped, and the zero-width spaces YouTube pads styled text with removed.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200B}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    public static func srt(_ cues: [Cue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n\n"
        }
        return out
    }

    private static func stamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
