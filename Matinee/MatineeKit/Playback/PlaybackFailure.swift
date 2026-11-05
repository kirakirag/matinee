import Foundation

public enum PlaybackFailure: Equatable, Sendable {
    case needsAccount, unavailable(String), network, timedOut, other(String)

    public static func classify(_ error: any Error) -> PlaybackFailure {
        guard let workerError = error as? WorkerError else { return .other(error.localizedDescription) }
        switch workerError {
        case .invalidID: return .other("Invalid video ID.")
        case .crashed: return .other("The video resolver stopped unexpectedly.")
        case .timedOut: return .timedOut
        case .failed(let message): return classify(message: message)
        }
    }

    private static func classify(message: String) -> PlaybackFailure {
        let text = message.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        if has("sign in to confirm", "age-restricted", "members-only", "join this channel", "login required", "use --cookies") {
            return .needsAccount
        }
        if has("private video") { return .unavailable("This video is private.") }
        if has("video unavailable", "has been removed") { return .unavailable("This video is unavailable.") }
        if has("live event will begin", "premieres in") { return .unavailable("This video hasn't started yet.") }
        if has("unable to download", "timed out", "connection") { return .network }
        return .other(message)
    }

    public var message: String {
        switch self {
        case .needsAccount: "This video won't play without a YouTube account"
        case .unavailable(let s): s
        case .network: "Can't reach YouTube. Check your connection."
        case .timedOut: "YouTube took too long to answer."
        case .other(let s): String(s.prefix(200))
        }
    }
}
