import Foundation

/// How a download's progress reads: "45% · 120 MB of 260 MB · 4.2 MB/s · 32 sec left".
public enum DownloadFormat {
    public static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    public static func detail(_ p: DownloadProgress) -> String {
        if p.stage == .finishing { return "Finishing…" }
        var parts: [String] = []
        if let fraction = p.fraction { parts.append("\(Int(fraction * 100))%") }
        parts.append(p.total.map { "\(bytes(p.downloaded)) of \(bytes($0))" } ?? bytes(p.downloaded))
        if let speed = p.speed, speed > 0 { parts.append("\(bytes(Int(speed)))/s") }
        if let eta = p.eta { parts.append(timeLeft(eta)) }
        return parts.joined(separator: " · ")
    }

    public static func timeLeft(_ seconds: Double) -> String {
        let d = Duration.seconds(max(1, seconds.rounded(.up)))
        return d.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)) + " left"
    }
}
