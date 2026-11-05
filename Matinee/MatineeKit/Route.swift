/// A page pushed onto a section's navigation stack.
public enum Route: Hashable, Sendable {
    case channel(ChannelRef, name: String?)
    case playlist(id: String, title: String?)
}
