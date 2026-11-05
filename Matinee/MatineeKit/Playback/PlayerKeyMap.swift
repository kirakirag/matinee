import Foundation

public enum PlayerCommand: Equatable, Sendable {
    case togglePause, seek(Double), volume(Int), speedStep(Int), fullscreen, exitFullscreen, close, next, previous, openChannel, quality, undoSkip, saveOffline, toggleComments, toggleSubscription
}

public enum SpecialKey: Sendable { case left, right, up, down, escape, space }

public enum PlayerKeyMap {
    /// Player keys. Any ⌘/⌥/⌃ gives nil, and shift only counts on `,` and `.` (how those arrive on some layouts) and on ⇧N / ⇧P.
    public static func command(_ chord: KeyChord, special: SpecialKey?) -> PlayerCommand? {
        guard !chord.command, !chord.option, !chord.control else { return nil }
        if let special {
            guard !chord.shift else { return nil }
            switch special {
            case .space: return .togglePause
            case .left: return .seek(-5)
            case .right: return .seek(5)
            case .up: return .volume(5)
            case .down: return .volume(-5)
            case .escape: return .close
            }
        }
        switch chord.key {
        case ",", "<": return .speedStep(-1)
        case ".", ">": return .speedStep(1)
        default: break
        }
        if chord.shift {
            switch chord.key {
            case "n": return .next
            case "p": return .previous
            default: return nil
            }
        }
        switch chord.key {
        case "c": return .openChannel
        case "q": return .quality
        case "u": return .undoSkip
        case "s": return .saveOffline
        case "-": return .volume(-5)
        case "=": return .volume(5)
        case "d": return .toggleSubscription
        case "o": return .toggleComments
        case " ": return .togglePause
        case "j": return .seek(-10)
        case "l": return .seek(10)
        case "f": return .fullscreen
        default: return nil
        }
    }
}
