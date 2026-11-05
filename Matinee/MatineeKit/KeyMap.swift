public enum AppSection: Int, CaseIterable, Sendable {
    /// For You only shows while Recommendations is on in Settings.
    case search, subscriptions, history, playlists, downloads, forYou, settings

    public var title: String {
        switch self {
        case .search: "Search"
        case .subscriptions: "Subscriptions"
        case .history: "History"
        case .playlists: "Playlists"
        case .downloads: "Downloads"
        case .forYou: "For You"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .subscriptions: "play.square.stack"
        case .history: "clock.arrow.circlepath"
        case .playlists: "list.bullet.rectangle"
        case .downloads: "arrow.down.circle"
        case .forYou: "sparkles"
        case .settings: "gearshape"
        }
    }
}

public struct KeyChord: Sendable, Equatable {
    public let key: String
    public let command, shift, option, control: Bool

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }
}

public enum GlobalCommand: Equatable, Sendable {
    case section(AppSection), focusSearch, filterList, refresh, resumePlayer, paste, delete, copyLink, toggleSidebar
}

public enum KeyMap {
    /// App-wide shortcuts. Only plain ⌘-chords: anything else belongs to the focused view or text field.
    public static func global(_ chord: KeyChord) -> GlobalCommand? {
        guard chord.command, !chord.shift, !chord.option, !chord.control else { return nil }
        if let n = Int(chord.key), let section = AppSection(rawValue: n - 1) { return .section(section) }
        switch chord.key {
        case ",": return .section(.settings)   // the Mac's usual Settings key
        case "f": return .focusSearch
        case "k": return .filterList
        case "r": return .refresh
        case "p": return .resumePlayer
        case "v": return .paste
        case "c": return .copyLink
        case "b": return .toggleSidebar
        case "\u{7f}": return .delete
        default: return nil
        }
    }

    /// ⌘V, ⌘⌫ and ⌘C belong to a focused text field (paste, delete to line start, copy); everything else is global.
    public static func shouldHandle(_ cmd: GlobalCommand, textFieldFocused: Bool) -> Bool {
        switch cmd {
        case .paste, .delete, .copyLink: !textFieldFocused
        default: true
        }
    }
}
