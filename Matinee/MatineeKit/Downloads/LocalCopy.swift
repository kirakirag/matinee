import Foundation

public enum LocalCopy {
    /// The finished download's file, or nil to stream: not saved, not finished, or removed (e.g. in Finder).
    public static func file(for d: Download?, in dir: URL = DownloadFiles.directory, exists: (URL) -> Bool) -> URL? {
        guard let d, d.state == .done, VideoID.isValid(d.videoId) else { return nil }
        let url = dir.appending(path: "\(d.videoId).mp4")
        return exists(url) ? url : nil
    }
}
