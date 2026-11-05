import Foundation

/// The text the JevK5 judge reads, character for character the prompt of the blind test that chose it
/// (`Scripts/recommendations`, `jevk5_prompt`): the viewer's profile as evidence, one candidate as the criterion,
/// and options A (would watch) and B (wouldn't). The judge's verdict is logit(A) − logit(B) at the answer position.
public enum JudgePrompt {
    /// `recent`, newest first: `watched` is the fraction watched, nil when unknown.
    public static func profile(subscriptions: [String], recent: [(title: String, channel: String, watched: Double?)],
                               dismissed: [String]) -> String {
        var text = "Channels they subscribe to: " + subscriptions.joined(separator: ", ")
            + "\n\nRecently watched, newest first:\n"
            + recent.map { r in
                "- \(r.title) — \(r.channel)" + (label(r.watched).map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
        if !dismissed.isEmpty {
            text += "\n\nThey said they're not interested in:\n" + dismissed.map { "- " + $0 }.joined(separator: "\n")
        }
        return text
    }

    /// The chat text up to the answer: the model's next token is A or B.
    public static func prompt(profile: String, candidate: (title: String, channel: String, seconds: Int?)) -> String {
        let video = "\(candidate.title) — \(candidate.channel)" + (length(candidate.seconds).map { " (\($0))" } ?? "")
        let payload = "{\"evidence\": \(json(profile)), \"criterion\": \(json(question + " The video: " + video)), "
            + "\"options\": [{\"letter\": \"A\", \"description\": \"true: Yes, they would want to watch it.\"}, "
            + "{\"letter\": \"B\", \"description\": \"false: No, they would not want to watch it.\"}]}"
        return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(payload)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    private static let question = "Would this viewer want to watch this YouTube video? Judge by their actual interests "
        + "and channels, not popularity; videos they left early count less."
    private static let system = "Apply the supplied criterion to the supplied evidence. Choose exactly one listed option. "
        + "Respond with only its uppercase letter, with no explanation or reasoning."

    private static func label(_ watched: Double?) -> String? {
        guard let f = watched else { return nil }
        return f > 0.85 ? "finished" : f < 0.2 ? "left early" : "partly"
    }

    private static func length(_ seconds: Int?) -> String? {
        guard let s = seconds, s != 0 else { return nil }
        return s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : "\(max(1, s / 60)) min"
    }

    /// A JSON string as Python's `json.dumps(ensure_ascii=False)` writes it, so the tokens match the tested prompt.
    static func json(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

/// The judge's re-sort of the top candidates: score = ln(1 / (1 + rank)) + weight × z(verdict), so the ranking's
/// order and the judge's relative confidence both count. Without a verdict for each, or with all verdicts equal, the
/// order is kept.
public enum JudgeFusion {
    public static func resort(_ top: [String], logits: [String: Double], weight: Double = 1.0) -> [String] {
        let values = top.compactMap { logits[$0] }
        guard values.count == top.count, top.count > 1 else { return top }
        let mean = values.reduce(0, +) / Double(values.count)
        let sd = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
        guard sd > 1e-9 else { return top }
        let score = Dictionary(uniqueKeysWithValues: top.enumerated().map { rank, id in
            (id, log(1 / Double(1 + rank)) + weight * (logits[id]! - mean) / sd)
        })
        return top.enumerated().sorted { a, b in
            score[a.element]! != score[b.element]! ? score[a.element]! > score[b.element]! : a.offset < b.offset
        }.map(\.element)
    }
}
