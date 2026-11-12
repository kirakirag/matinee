public enum KeyRoute: Equatable, Sendable {
    case global(GlobalCommand), player(PlayerCommand), qualityMenu(QualityMenuKey), panel(PanelKey), openBrave, pop
    /// Handled with no effect (keeps the hidden list from moving under the player).
    case swallow
    /// Not ours: the event goes on to the focused view.
    case pass
}

public enum QualityMenuKey: Equatable, Sendable { case up, down, apply, close }

/// The player's side panel while it's open: ↑/↓ move its selection, Return acts on it, Tab switches Up next and
/// Comments, Escape closes it.
public enum PanelKey: Equatable, Sendable { case up, down, activate, switchTab, close }

public enum KeyRouting {
    /// Decides what the window-level key monitor does with a key press, in priority order:
    /// global ⌘-chords, Escape popping a pushed page, Q W E R T Y picking a section, then player keys while the
    /// player is up.
    /// While the player's quality list is open, it takes ↑/↓/Return/Escape and no other player key acts.
    /// While its side panel is open, the panel takes ↑/↓/Return/Tab/Escape; the other player keys still act.
    /// Otherwise Escape in fullscreen leaves fullscreen, and only the next one closes the player.
    /// While the player is up, a focused text field is ignored and ⌘⌫ does nothing.
    public static func route(chord: KeyChord, keyCode: UInt16, special: SpecialKey?, playerPresented: Bool,
                             textFieldFocused: Bool, hasRoute: Bool, playerNeedsAccount: Bool,
                             qualityMenuOpen: Bool, fullscreen: Bool, panelOpen: Bool = false,
                             playerMini: Bool = false) -> KeyRoute {
        // The player covers every text field, so one still focused underneath must not take its keys.
        let textFieldFocused = textFieldFocused && !playerPresented
        // ⌘⌫ reports its character inconsistently, so go by the key code.
        let chord = keyCode == 51 ? KeyChord(key: "\u{7f}", command: chord.command, shift: chord.shift,
                                             option: chord.option, control: chord.control) : chord
        if let cmd = KeyMap.global(chord) {
            // ⌘⌫ would act on the list hidden under the player.
            if cmd == .delete, playerPresented { return .swallow }
            return KeyMap.shouldHandle(cmd, textFieldFocused: textFieldFocused) ? .global(cmd) : .pass
        }
        // ⌘Escape stops the video, whether it fills the window or plays in the mini player.
        if special == .escape, chord.command, !chord.shift, !chord.option, !chord.control, playerPresented || playerMini {
            return .player(.stop)
        }
        let plain = !chord.command && !chord.shift && !chord.option && !chord.control
        if special == .escape, plain, !textFieldFocused, !playerPresented {
            return hasRoute ? .pop : .pass
        }
        // Q W E R T Y pick the sections in sidebar order: one left-hand key next to the home row, while the right hand
        // stays on j/k and Return. Not while typing, nor over the player.
        if plain, !textFieldFocused, !playerPresented, let i = Array("qwerty").firstIndex(of: Character(chord.key)),
           let section = AppSection(rawValue: i) {
            return .global(.section(section))
        }
        guard playerPresented, !textFieldFocused, !chord.command, !chord.option, !chord.control else { return .pass }
        if qualityMenuOpen {
            if chord.shift { return .swallow }
            if keyCode == 36 || keyCode == 76 { return .qualityMenu(.apply) }
            switch special {
            case .up: return .qualityMenu(.up)
            case .down: return .qualityMenu(.down)
            case .escape: return .qualityMenu(.close)
            default: return .swallow
            }
        }
        if panelOpen, !chord.shift {
            if keyCode == 36 || keyCode == 76 { return .panel(.activate) }
            if keyCode == 48 { return .panel(.switchTab) }
            switch special {
            case .up: return .panel(.up)
            case .down: return .panel(.down)
            case .escape: return .panel(.close)
            default: break
            }
        }
        if special == .escape, !chord.shift, fullscreen { return .player(.exitFullscreen) }
        if keyCode == 36 || keyCode == 76, playerNeedsAccount { return .openBrave }
        return PlayerKeyMap.command(chord, special: special).map(KeyRoute.player) ?? .swallow
    }
}
