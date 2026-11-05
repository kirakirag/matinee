import Foundation

/// Bytes of a download so far; `total` is nil while yt-dlp doesn't know it.
public struct DownloadProgress: Sendable, Equatable, Decodable {
    public enum Stage: String, Sendable, Decodable { case downloading, finishing }

    /// Bytes so far, video and audio together.
    public let downloaded: Int
    /// The whole download's bytes; nil while a file's size can't be known.
    public let total: Int?
    /// 0…1, never going back; nil while the total is unknown.
    public let fraction: Double?
    /// Bytes per second over the last few seconds.
    public let speed: Double?
    /// Seconds left at that speed.
    public let eta: Double?
    /// Finishing: everything is downloaded and the files are being merged.
    public let stage: Stage

    public init(downloaded: Int, total: Int?, fraction: Double? = nil, speed: Double? = nil, eta: Double? = nil,
                stage: Stage = .downloading) {
        self.downloaded = downloaded
        self.total = total
        self.fraction = fraction
        self.speed = speed
        self.eta = eta
        self.stage = stage
    }

    private enum CodingKeys: String, CodingKey { case downloaded, total, fraction, speed, eta, stage }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloaded = try c.decode(Int.self, forKey: .downloaded)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed)
        eta = try c.decodeIfPresent(Double.self, forKey: .eta)
        stage = (try? c.decodeIfPresent(Stage.self, forKey: .stage)) ?? .downloading
    }
}

/// A finished download: the merged file and the metadata yt-dlp read on the way.
public struct Downloaded: Decodable, Sendable {
    public let file: String
    public let bytes: Int
    public let title: String?
    public let channel: String?
    public let channelId: String?
    public let duration: Double?
}
