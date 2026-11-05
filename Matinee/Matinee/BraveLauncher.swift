import AppKit
import MatineeKit

/// Opens a video in Brave, for videos that won't play without a YouTube account.
enum BraveLauncher {
    struct NotInstalled: LocalizedError {
        var errorDescription: String? { "Brave isn't installed." }
    }

    static func open(videoId: String, profile: String?) async throws {
        guard VideoID.isValid(videoId) else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") else { throw NotInstalled() }
        let url = "https://www.youtube.com/watch?v=\(videoId)"
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = profileFlag(profile).map { [$0, url] } ?? [url]
        // A running Brave ignores `arguments` unless a new instance is launched; Chromium's singleton then hands the
        // command line (URL and profile) to the running browser and the new process exits (`open -na … --args`).
        config.createsNewApplicationInstance = true
        try await NSWorkspace.shared.openApplication(at: app, configuration: config)
    }

    /// Only a plain profile directory name becomes a flag, so a typed value can't turn into another flag.
    private static func profileFlag(_ profile: String?) -> String? {
        guard let p = profile?.trimmingCharacters(in: .whitespacesAndNewlines),
              p.wholeMatch(of: /[A-Za-z0-9 _-]{1,64}/) != nil else { return nil }
        return "--profile-directory=\(p)"
    }
}
