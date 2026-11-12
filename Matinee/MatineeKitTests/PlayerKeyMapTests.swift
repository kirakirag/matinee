import Testing
@testable import MatineeKit

struct PlayerKeyMapTests {
    private func cmd(_ key: String, special: SpecialKey? = nil, shift: Bool = false) -> PlayerCommand? {
        PlayerKeyMap.command(KeyChord(key: key, shift: shift), special: special)
    }

    @Test func table() {
        #expect(cmd(" ", special: .space) == .togglePause)
        #expect(cmd(" ") == .togglePause)
        #expect(cmd("", special: .left) == .seek(-5))
        #expect(cmd("", special: .right) == .seek(5))
        #expect(cmd("j") == .seek(-10))
        #expect(cmd("l") == .seek(10))
        #expect(cmd("", special: .up) == .volume(5))
        #expect(cmd("", special: .down) == .volume(-5))
        #expect(cmd("f") == .fullscreen)
        #expect(cmd("i") == nil)
        #expect(cmd(",") == .speedStep(-1))
        #expect(cmd(".") == .speedStep(1))
        #expect(cmd("", special: .escape) == .close)
    }

    @Test func shiftedSpeedKeys() {
        #expect(cmd(",", shift: true) == .speedStep(-1))
        #expect(cmd(".", shift: true) == .speedStep(1))
        #expect(cmd("<", shift: true) == .speedStep(-1))
        #expect(cmd(">", shift: true) == .speedStep(1))
        #expect(cmd("j", shift: true) == nil)
        #expect(cmd("", special: .left, shift: true) == nil)
    }

    @Test func shiftNAndShiftP() {
        #expect(cmd("n", shift: true) == .next)
        #expect(cmd("p", shift: true) == .previous)
        #expect(cmd("n") == nil)
        #expect(cmd("p") == nil)
    }

    @Test func plainCOpensChannel() {
        #expect(cmd("c") == .openChannel)
        #expect(cmd("c", shift: true) == nil)
    }

    @Test func qOpensQuality() {
        #expect(cmd("q") == .quality)
        #expect(cmd("q", shift: true) == nil)
        #expect(cmd("v") == .subtitles)
        #expect(cmd("a") == .audio)
    }

    @Test func cmdSpaceIsNotPlayer() {
        #expect(PlayerKeyMap.command(KeyChord(key: " ", command: true), special: nil) == nil)
        #expect(PlayerKeyMap.command(KeyChord(key: " ", command: true), special: .space) == nil)
        #expect(PlayerKeyMap.command(KeyChord(key: "f", option: true), special: nil) == nil)
        #expect(PlayerKeyMap.command(KeyChord(key: "f", control: true), special: nil) == nil)
    }

    @Test func shiftSpaceIsNotPlayer() {
        #expect(cmd(" ", special: .space, shift: true) == nil)
        #expect(cmd(" ", shift: true) == nil)
    }

    @Test func plainJIsSeekBack() {
        #expect(PlayerKeyMap.command(KeyChord(key: "j"), special: nil) == .seek(-10))
    }

    @Test func uUndoesTheLastSkip() {
        #expect(PlayerKeyMap.command(KeyChord(key: "u"), special: nil) == .undoSkip)
        #expect(PlayerKeyMap.command(KeyChord(key: "u", command: true), special: nil) == nil)
    }

    @Test func sSavesOfflineInThePlayer() {
        #expect(PlayerKeyMap.command(KeyChord(key: "s"), special: nil) == .saveOffline)
        #expect(PlayerKeyMap.command(KeyChord(key: "s", shift: true), special: nil) == nil)
    }

    @Test func minusAndEqualsSetTheVolumeEvenWhileThePanelHasTheArrows() {
        #expect(PlayerKeyMap.command(KeyChord(key: "-"), special: nil) == .volume(-5))
        #expect(PlayerKeyMap.command(KeyChord(key: "="), special: nil) == .volume(5))
    }

    @Test func dTogglesTheSubscriptionInThePlayer() {
        #expect(PlayerKeyMap.command(KeyChord(key: "d"), special: nil) == .toggleSubscription)
        #expect(PlayerKeyMap.command(KeyChord(key: "d", command: true), special: nil) == nil)
    }

    @Test func oTogglesComments() {
        #expect(PlayerKeyMap.command(KeyChord(key: "o"), special: nil) == .toggleComments)
        #expect(PlayerKeyMap.command(KeyChord(key: "o", command: true), special: nil) == nil)
    }
}
