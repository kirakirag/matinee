import Foundation

/// Parses a channel's YouTube Atom feed (`/feeds/videos.xml?channel_id=`). Shorts, and entries
/// with invalid IDs or missing fields, are dropped.
public enum RSSParser {
    public enum Error: Swift.Error { case malformed }

    public static func parse(_ data: Data) throws -> [FeedVideo] {
        let collector = EntryCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        guard parser.parse() else { throw Error.malformed }
        return collector.videos
    }
}

private final class EntryCollector: NSObject, XMLParserDelegate {
    private(set) var videos: [FeedVideo] = []
    private var inEntry = false
    private var text = ""
    private var videoId: String?
    private var channelId: String?
    private var title: String?
    private var published: String?
    private var author: String?
    private var views: Int?
    private var isShort = false
    /// One per feed, not per entry: creating a formatter costs more than parsing a date with it.
    private let dates = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes attributeDict: [String: String]) {
        if elementName == "entry" {
            inEntry = true
            videoId = nil; channelId = nil; title = nil; published = nil; author = nil; views = nil; isShort = false
        }
        guard inEntry else { return }
        text = ""
        switch elementName {
        case "link" where attributeDict["href"]?.contains("/shorts/") == true:
            isShort = true
        case "media:statistics":
            views = attributeDict["views"].flatMap { Int($0) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        guard inEntry else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "entry": finishEntry(); inEntry = false
        case "yt:videoId": videoId = value
        case "yt:channelId": channelId = value
        case "title": title = value
        case "published": published = value
        case "name": author = value
        default: break
        }
    }

    private func finishEntry() {
        guard !isShort,
              let videoId, VideoID.isValid(videoId),
              let channelId, ChannelID.isValid(channelId),
              let title, !title.isEmpty,
              let published, let publishedAt = dates.date(from: published) else { return }
        videos.append(FeedVideo(videoId: videoId, channelId: channelId, channelName: author ?? "",
                                title: title, publishedAt: publishedAt, views: views))
    }
}
