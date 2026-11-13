import Testing
import MatineeKit

private func route(_ key: String, code: UInt16 = 0, command: Bool = false, shift: Bool = false, special: SpecialKey? = nil,
                   player: Bool = false, field: Bool = false, hasRoute: Bool = false, needsAccount: Bool = false,
                   qualityMenu: Bool = false, fullscreen: Bool = false, panel: Bool = false) -> KeyRoute {
    KeyRouting.route(chord: KeyChord(key: key, command: command, shift: shift), keyCode: code, special: special,
                     playerPresented: player, textFieldFocused: field, hasRoute: hasRoute, playerNeedsAccount: needsAccount,
                     qualityMenuOpen: qualityMenu, fullscreen: fullscreen, panelOpen: panel)
}

@Test func escapeWithPlayerUpClosesPlayer() {
    #expect(route("\u{1b}", code: 53, special: .escape, player: true, hasRoute: true) == .player(.close))
}

@Test func cmdWStopsTheVideoFullOrMini() {
    let stop = KeyChord(key: "w", command: true)
    func r(player: Bool, mini: Bool, fullscreen: Bool = false) -> KeyRoute {
        KeyRouting.route(chord: stop, keyCode: 13, special: nil, playerPresented: player, textFieldFocused: false,
                         hasRoute: true, playerNeedsAccount: false, qualityMenuOpen: false, fullscreen: fullscreen,
                         playerMini: mini)
    }
    #expect(r(player: true, mini: false) == .player(.stop))
    #expect(r(player: true, mini: false, fullscreen: true) == .player(.stop))
    #expect(r(player: false, mini: true) == .player(.stop))
    #expect(r(player: false, mini: false) == .pass)
}

@Test func escapeInFullscreenLeavesFullscreen() {
    #expect(route("\u{1b}", code: 53, special: .escape, player: true, fullscreen: true) == .player(.exitFullscreen))
    #expect(route("\u{1b}", code: 53, special: .escape, player: true, qualityMenu: true, fullscreen: true) == .qualityMenu(.close))
}

@Test func escapeInTextFieldPasses() {
    #expect(route("\u{1b}", code: 53, special: .escape, field: true, hasRoute: true) == .pass)
}

@Test func escapePopsOnlyWithARoute() {
    #expect(route("\u{1b}", code: 53, special: .escape, hasRoute: true) == .pop)
    #expect(route("\u{1b}", code: 53, special: .escape) == .pass)
}

@Test func cmdDeleteByKeyCodeIsGlobalOutsideTextField() {
    #expect(route("x", code: 51, command: true) == .global(.delete))
    #expect(route("x", code: 51, command: true, field: true) == .pass)
}

@Test func cmdVIsGlobalOutsideTextField() {
    #expect(route("v", command: true) == .global(.paste))
    #expect(route("v", command: true, field: true) == .pass)
}

@Test func plainKeysWithPlayerUpGoToPlayerOrAreSwallowed() {
    #expect(route("c", player: true) == .player(.openChannel))
    #expect(route("x", player: true) == .swallow)
    #expect(route("q", player: true) == .player(.quality))
    #expect(route("x") == .pass)
    #expect(route("c", player: true, field: true) == .player(.openChannel))
}

@Test func returnOpensBraveWhenAccountNeeded() {
    #expect(route("\r", code: 36, player: true, needsAccount: true) == .openBrave)
    #expect(route("\r", code: 36, player: true) == .swallow)
}

@Test func qualityMenuTakesItsKeysAndSwallowsPlayerKeys() {
    #expect(route("", code: 126, special: .up, player: true, qualityMenu: true) == .qualityMenu(.up))
    #expect(route("", code: 125, special: .down, player: true, qualityMenu: true) == .qualityMenu(.down))
    #expect(route("\r", code: 36, player: true, needsAccount: true, qualityMenu: true) == .qualityMenu(.apply))
    #expect(route("\u{1b}", code: 53, special: .escape, player: true, qualityMenu: true) == .qualityMenu(.close))
    #expect(route(" ", code: 49, special: .space, player: true, qualityMenu: true) == .swallow)
    #expect(route("c", player: true, qualityMenu: true) == .swallow)
    #expect(route("1", command: true, player: true, qualityMenu: true) == .global(.section(.search)))
}

@Test func cmdCIsCopyLinkOutsideTextField() {
    #expect(route("c", command: true) == .global(.copyLink))
    #expect(route("c", command: true, player: true) == .global(.copyLink))
}

@Test func cmdCPassesThroughInTextField() {
    #expect(route("c", command: true, field: true) == .pass)
}

@Test func playerKeysWinOverAHiddenFocusedTextField() {
    #expect(route(" ", code: 49, special: .space, player: true, field: true) == .player(.togglePause))
    #expect(route("\u{1b}", code: 53, special: .escape, player: true, field: true) == .player(.close))
    #expect(route("\u{1b}", code: 53, special: .escape, player: true, field: true, fullscreen: true) == .player(.exitFullscreen))
    #expect(route("v", command: true, player: true, field: true) == .global(.paste))
    #expect(route("c", command: true, player: true, field: true) == .global(.copyLink))
}

@Test func cmdDeleteWithPlayerUpIsSwallowed() {
    #expect(route("x", code: 51, command: true, player: true) == .swallow)
    #expect(route("x", code: 51, command: true, player: true, field: true) == .swallow)
}

@Test func qwertySwitchSectionsOutsideTextFieldsAndThePlayer() {
    #expect(route("q") == .global(.section(.search)))
    #expect(route("w") == .global(.section(.subscriptions)))
    #expect(route("e") == .global(.section(.history)))
    #expect(route("r") == .global(.section(.playlists)))
    #expect(route("t") == .global(.section(.downloads)))
    #expect(route("y") == .global(.section(.forYou)))
    #expect(route("u") == .pass)
    #expect(route("1") == .pass)
    #expect(route("w", field: true) == .pass)
    #expect(route("w", player: true) == .swallow)
}

@Test func theOpenSidePanelTakesArrowsReturnTabAndEscape() {
    #expect(route("", special: .up, player: true, panel: true) == .panel(.up))
    #expect(route("", special: .down, player: true, panel: true) == .panel(.down))
    #expect(route("\r", code: 36, player: true, panel: true) == .panel(.activate))
    #expect(route("\t", code: 48, player: true, panel: true) == .panel(.switchTab))
    #expect(route("", special: .escape, player: true, panel: true) == .panel(.close))
    #expect(route("", special: .escape, player: true, fullscreen: true, panel: true) == .panel(.close))
    // Everything else is still the player's.
    #expect(route("", special: .left, player: true, panel: true) == .player(.seek(-5)))
    #expect(route("o", player: true, panel: true) == .player(.toggleComments))
    // Closed, the arrows are the volume again and Tab does nothing.
    #expect(route("", special: .up, player: true) == .player(.volume(5)))
    #expect(route("\t", code: 48, player: true) == .swallow)
}
