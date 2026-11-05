import Foundation

/// A video saved, or being saved, for offline viewing.
public struct Download: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case queued, downloading, done, failed(String) }

    public let videoId: String
    public var title: String
    public var channelName: String
    public var channelId: String?
    public var lengthSeconds: Int?
    public var state: State
    public var bytes: Int?
    public let addedAt: Date
    public var id: String { videoId }

    public init(videoId: String, title: String, channelName: String, channelId: String?, lengthSeconds: Int?,
                state: State, bytes: Int?, addedAt: Date) {
        self.videoId = videoId
        self.title = title
        self.channelName = channelName
        self.channelId = channelId
        self.lengthSeconds = lengthSeconds
        self.state = state
        self.bytes = bytes
        self.addedAt = addedAt
    }
}

public enum DownloadQueue {
    /// After a launch nothing is downloading yet: rows left `downloading` by a quit or crash go back to the queue
    /// (yt-dlp resumes their `.part` files).
    public static func requeueInterrupted(_ downloads: [Download]) -> [Download] {
        downloads.map { d in
            var d = d
            if d.state == .downloading { d.state = .queued }
            return d
        }
    }
}

public enum DownloadFiles {
    /// `~/Movies/Matinee` in the real home folder: the sandbox's Movies entitlement covers it, and the container's own
    /// Movies folder would hide the files from Finder.
    public static let directory: URL = {
        let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
        return URL(filePath: home, directoryHint: .isDirectory).appending(path: "Movies/Matinee", directoryHint: .isDirectory)
    }()

    public static func file(videoId: String) -> URL { directory.appending(path: "\(videoId).mp4") }

    /// Deletes the video's file and every partial one (`<id>.mp4.part`, `<id>.f137.mp4`, …).
    public static func removeAll(videoId: String, in dir: URL) throws {
        guard VideoID.isValid(videoId) else { throw WorkerError.invalidID }
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix(videoId + ".") {
            try FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }
}
