import Foundation

/// HTTP for third-party services (YouTube's RSS, Google's suggestions, DeArrow, SponsorBlock, thumbnails) without
/// cookies or stored credentials. `URLSession.shared` stores any cookie a server sets and sends it back, which would
/// give every feed refresh and every typed search one stable identifier.
public enum PrivateHTTP {
    public static let session = URLSession(configuration: configuration(cache: nil))

    /// Ephemeral, without cookies or credentials; `cache` keeps responses (e.g. thumbnails), nil keeps none on disk.
    public static func configuration(cache: URLCache?) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        if let cache { config.urlCache = cache }
        return config
    }
}
