import Foundation
import Testing
import MatineeKit

@Test func videoIDBounds() {
    #expect(VideoID.isValid("testVideo01"))
    #expect(VideoID.isValid("a-_0Z9zAaaa"))
    #expect(!VideoID.isValid("testVideo0"))
    #expect(!VideoID.isValid("testVideo01Q"))
    #expect(!VideoID.isValid("testVideo0!"))
    #expect(!VideoID.isValid("testVideo0."))
    #expect(!VideoID.isValid(" testVideo0"))
    #expect(!VideoID.isValid("testVideo0é"))
    #expect(!VideoID.isValid("testVideo0e\u{301}"))   // one Character, two scalars
    #expect(!VideoID.isValid(""))
}

@Test func playlistIDBounds() {
    #expect(PlaylistID.isValid(String(repeating: "a", count: 12)))
    #expect(PlaylistID.isValid(String(repeating: "_", count: 64)))
    #expect(!PlaylistID.isValid(String(repeating: "a", count: 11)))
    #expect(!PlaylistID.isValid(String(repeating: "a", count: 65)))
    #expect(!PlaylistID.isValid("PL" + String(repeating: "a", count: 12) + "&"))
}

@Test func channelIDBounds() {
    #expect(ChannelID.isValid("UC" + String(repeating: "a", count: 22)))
    #expect(ChannelID.isValid("UC" + String(repeating: "-", count: 22)))
    #expect(!ChannelID.isValid("UC" + String(repeating: "a", count: 21)))
    #expect(!ChannelID.isValid("UC" + String(repeating: "a", count: 23)))
    #expect(!ChannelID.isValid("uc" + String(repeating: "a", count: 22)))
    #expect(!ChannelID.isValid("UC" + String(repeating: "a", count: 21) + "."))
    #expect(!ChannelID.isValid(String(repeating: "a", count: 24)))
}

@Test func channelHandleBounds() {
    #expect(ChannelHandle.isValid("@abc"))
    #expect(ChannelHandle.isValid("@" + String(repeating: ".", count: 30)))
    #expect(!ChannelHandle.isValid("@ab"))
    #expect(!ChannelHandle.isValid("@" + String(repeating: "a", count: 31)))
    #expect(!ChannelHandle.isValid("abcd"))
    #expect(!ChannelHandle.isValid("@ab@c"))
    #expect(!ChannelHandle.isValid("@abc/"))
    #expect(!ChannelHandle.isValid("@"))
}
