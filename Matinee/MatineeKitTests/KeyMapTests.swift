import Testing
import MatineeKit

@Test func commandDigitsSwitchSections() {
    for (i, s) in AppSection.allCases.enumerated() {
        #expect(KeyMap.global(KeyChord(key: "\(i + 1)", command: true)) == .section(s))
    }
    #expect(KeyMap.global(KeyChord(key: "\(AppSection.allCases.count + 1)", command: true)) == nil)
}

@Test func commandCommaOpensSettings() {
    #expect(KeyMap.global(KeyChord(key: ",", command: true)) == .section(.settings))
    #expect(KeyMap.global(KeyChord(key: ",")) == nil)
}

@Test func findFilterRefresh() {
    #expect(KeyMap.global(KeyChord(key: "f", command: true)) == .focusSearch)
    #expect(KeyMap.global(KeyChord(key: "k", command: true)) == .filterList)
    #expect(KeyMap.global(KeyChord(key: "r", command: true)) == .refresh)
}

@Test func cmdPResumesPlayer() {
    #expect(KeyMap.global(KeyChord(key: "p", command: true)) == .resumePlayer)
}

@Test func plainLettersAreNotGlobal() {   // Review Focus 5
    for k in ["j", "k", "f", "1", "s"] { #expect(KeyMap.global(KeyChord(key: k)) == nil) }
    #expect(KeyMap.global(KeyChord(key: "1", command: true, shift: true)) == nil)
}

@Test func cmdVIsPaste() {
    #expect(KeyMap.global(KeyChord(key: "v", command: true)) == .paste)
}

@Test func cmdDeleteIsDelete() {
    #expect(KeyMap.global(KeyChord(key: "\u{7f}", command: true)) == .delete)
}

@Test func pasteAndDeleteNotHandledInTextField() {
    #expect(!KeyMap.shouldHandle(.paste, textFieldFocused: true))
    #expect(!KeyMap.shouldHandle(.delete, textFieldFocused: true))
    #expect(KeyMap.shouldHandle(.paste, textFieldFocused: false))
    #expect(KeyMap.shouldHandle(.section(.search), textFieldFocused: true))
}

@Test func cmdBTogglesSidebar() {
    #expect(KeyMap.global(KeyChord(key: "b", command: true)) == .toggleSidebar)
    #expect(KeyMap.shouldHandle(.toggleSidebar, textFieldFocused: true))
}
