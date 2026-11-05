import Testing
@testable import MatineeKit

struct PlaybackFailureTests {
    private func classify(_ message: String) -> PlaybackFailure {
        PlaybackFailure.classify(WorkerError.failed(message))
    }

    @Test func ageGateNeedsAccount() {
        #expect(classify("Sign in to confirm your age. This video may be inappropriate for some users.") == .needsAccount)
    }

    @Test func botCheckNeedsAccount() {
        #expect(classify("Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication.") == .needsAccount)
    }

    @Test func membersOnlyNeedsAccount() {
        #expect(classify("Join this channel to get access to members-only content like this video, and other exclusive perks.") == .needsAccount)
    }

    @Test func privateVideo() {
        #expect(classify("Private video. Sign in if you've been granted access to this video") == .unavailable("This video is private."))
    }

    @Test func removedVideo() {
        #expect(classify("Video unavailable. This video has been removed by the uploader") == .unavailable("This video is unavailable."))
    }

    @Test func upcomingLiveEvent() {
        #expect(classify("This live event will begin in 3 hours.") == .unavailable("This video hasn't started yet."))
    }

    @Test func networkMessages() {
        #expect(classify("Unable to download webpage") == .network)
        #expect(classify("Read timed out") == .network)
        #expect(classify("Connection reset by peer") == .network)
    }

    @Test func workerStates() {
        #expect(PlaybackFailure.classify(WorkerError.timedOut) == .timedOut)
        #expect(PlaybackFailure.classify(WorkerError.crashed) == .other("The video resolver stopped unexpectedly."))
        #expect(PlaybackFailure.classify(WorkerError.invalidID) == .other("Invalid video ID."))
    }

    @Test func unknownMessageIsOther() {
        #expect(classify("Something odd") == .other("Something odd"))
    }

    @Test func messages() {
        #expect(PlaybackFailure.needsAccount.message == "This video won't play without a YouTube account")
        #expect(PlaybackFailure.network.message == "Can't reach YouTube. Check your connection.")
        #expect(PlaybackFailure.timedOut.message == "YouTube took too long to answer.")
        #expect(PlaybackFailure.unavailable("This video is private.").message == "This video is private.")
        #expect(PlaybackFailure.other(String(repeating: "x", count: 300)).message.count == 200)
    }
}
