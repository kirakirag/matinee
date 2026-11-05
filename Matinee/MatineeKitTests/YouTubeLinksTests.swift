import Foundation
import Testing
@testable import MatineeKit

struct YouTubeLinksTests {
    static let uc = "UCXuqSBlHAE6Xw-yeJA0Tunw"
    static let pl = "PLtestPlaylist00000000000000000000"

    @Test func parsesChannelForms() {
        #expect(ChannelRef.parse(Self.uc) == .id(Self.uc))
        #expect(ChannelRef.parse("@LinusTechTips") == .handle("@LinusTechTips"))
        #expect(ChannelRef.parse("https://www.youtube.com/channel/\(Self.uc)") == .id(Self.uc))
        #expect(ChannelRef.parse("http://youtube.com/channel/\(Self.uc)/videos?x=1") == .id(Self.uc))
        #expect(ChannelRef.parse("https://youtube.com/@LinusTechTips") == .handle("@LinusTechTips"))
        #expect(ChannelRef.parse("https://m.youtube.com/@LinusTechTips/videos") == .handle("@LinusTechTips"))
    }

    @Test func parsesPlaylistLinks() {
        #expect(PlaylistLink.parse("https://www.youtube.com/watch?v=testVideo01&list=\(Self.pl)") == Self.pl)
        #expect(PlaylistLink.parse("https://youtube.com/playlist?list=\(Self.pl)") == Self.pl)
        #expect(PlaylistLink.parse("https://youtu.be/testVideo01?list=\(Self.pl)") == Self.pl)
        #expect(PlaylistLink.parse(Self.pl) == Self.pl)
    }

    @Test func rejectsJunk() {
        for junk in ["hello", "https://evil.com/@x", "@a", "UC123", "https://www.youtube.com/c/foo",
                     "https://www.youtube.com/user/foo", "list=--", String(repeating: "a", count: 300)] {
            #expect(ChannelRef.parse(junk) == nil, "\(junk)")
            #expect(PlaylistLink.parse(junk) == nil, "\(junk)")
            #expect(PastedLink.parse(junk) == nil, "\(junk)")
        }
    }

    @Test func parsesPastedLinks() {
        #expect(PastedLink.parse("https://youtu.be/testVideo01?t=43") == .video(id: "testVideo01", start: 43))
        #expect(PastedLink.parse("https://www.youtube.com/watch?v=testVideo01&list=\(Self.pl)&t=1m2s")
            == .video(id: "testVideo01", start: 62))
        #expect(PastedLink.parse("https://youtube.com/shorts/testVideo01") == .video(id: "testVideo01", start: nil))
        #expect(PastedLink.parse("https://music.youtube.com/watch?v=testVideo01&start=90s")
            == .video(id: "testVideo01", start: 90))
        #expect(PastedLink.parse("https://youtube.com/live/testVideo01?t=1h2m3s")
            == .video(id: "testVideo01", start: 3723))
        #expect(PastedLink.parse("https://youtube.com/embed/testVideo01?t=90") == .video(id: "testVideo01", start: 90))
        #expect(PastedLink.parse("https://youtu.be/testVideo01?t=soon") == .video(id: "testVideo01", start: nil))
        #expect(PastedLink.parse("https://youtube.com/playlist?list=\(Self.pl)") == .playlist(Self.pl))
        #expect(PastedLink.parse("@LinusTechTips") == .channel(.handle("@LinusTechTips")))
        #expect(PastedLink.parse("https://www.youtube.com/channel/\(Self.uc)") == .channel(.id(Self.uc)))
    }

    @Test func pastedLinkIgnoresPlainText() {
        #expect(PastedLink.parse("testVideo01") == nil)
        #expect(PastedLink.parse("never gonna give you up") == nil)
        #expect(PastedLink.parse("https://youtube.com/watch?v=short") == nil)
        #expect(PastedLink.parse(Self.uc) == nil)
    }

    @Test func searchURLEncodesQuery() {
        let url = YouTubeURL.search("a&b c/ü#", SearchFilter(type: .channel)).url
        #expect(url?.absoluteString == "https://www.youtube.com/results?search_query=a%26b%20c%2F%C3%BC%23&sp=EgIQAg%3D%3D")
        #expect(YouTubeURL.search("cats", SearchFilter()).url?.absoluteString
            == "https://www.youtube.com/results?search_query=cats")
    }

    @Test func emptyQueryHasNoURL() {
        #expect(YouTubeURL.search("", SearchFilter()).url == nil)
        #expect(YouTubeURL.search("  \n ", SearchFilter()).url == nil)
    }

    @Test func channelAndPlaylistURLs() {
        #expect(YouTubeURL.channelPlaylists(.id(Self.uc)).url?.absoluteString
            == "https://www.youtube.com/channel/\(Self.uc)/playlists")
        #expect(YouTubeURL.channelPlaylists(.handle("@LinusTechTips")).url?.absoluteString
            == "https://www.youtube.com/@LinusTechTips/playlists")
        #expect(YouTubeURL.playlist(Self.pl).url?.absoluteString == "https://www.youtube.com/playlist?list=\(Self.pl)")
        #expect(YouTubeURL.channel(.id(Self.uc)).url?.absoluteString == "https://www.youtube.com/channel/\(Self.uc)")
        #expect(YouTubeURL.channel(.handle("@LinusTechTips")).url?.absoluteString == "https://www.youtube.com/@LinusTechTips")
        #expect(YouTubeURL.channel(.id("UC123")).url == nil)
        #expect(YouTubeURL.channelPlaylists(.id("UC123")).url == nil)
        #expect(YouTubeURL.channelPlaylists(.handle("@a")).url == nil)
        #expect(YouTubeURL.playlist("bad").url == nil)
    }

    @Test func watchURLForValidId() {
        #expect(YouTubeURL.watchURL(videoId: "testVideo01")?.absoluteString == "https://www.youtube.com/watch?v=testVideo01")
    }

    @Test func watchURLNilForInvalidId() {
        #expect(YouTubeURL.watchURL(videoId: "short") == nil)
        #expect(YouTubeURL.watchURL(videoId: "testVideo0&") == nil)
    }

    @Test func idValidators() {
        #expect(PlaylistID.isValid(Self.pl))
        #expect(!PlaylistID.isValid("short"))
        #expect(!PlaylistID.isValid(String(repeating: "a", count: 65)))
        #expect(ChannelHandle.isValid("@a.b_c-d"))
        #expect(!ChannelHandle.isValid("LinusTechTips"))
        #expect(!ChannelHandle.isValid("@" + String(repeating: "a", count: 31)))
    }
}
