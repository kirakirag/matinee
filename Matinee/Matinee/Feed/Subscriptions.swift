import Foundation
import MatineeKit
import Observation

/// The subscribed channels, shared by every view, so `d` anywhere, the Subscribe buttons and the channel list agree.
@MainActor @Observable
final class Subscriptions {
    /// The channel list, by name. A channel unsubscribed this session stays listed (dimmed) until `prune`, so `d` can
    /// undo it.
    private(set) var channels: [Channel] = []
    private(set) var ids: Set<String> = []
    /// Until the stored subscriptions are read, toggling could overwrite one or miss that it exists.
    private(set) var isLoaded = false
    /// Set by the app: the feed refreshes after a change.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Set by the app: "Subscribed to …" and errors, shown in the window.
    @ObservationIgnored var onNotice: ((String) -> Void)?

    private let store: Store

    init(store: Store) {
        self.store = store
    }

    func load() async {
        let store = store
        let saved = await Task.detached { (try? store.subscriptions()) ?? [] }.value
        channels = saved
        ids = Set(saved.map(\.id))
        ChannelAvatars.shared.add(saved)
        isLoaded = true
    }

    func contains(_ id: String?) -> Bool { id.map(ids.contains) ?? false }

    /// Subscribes to the channel, or unsubscribes when subscribed. Saving a new one needs its name.
    func toggle(_ id: String?, name: String?, thumbnail: URL? = nil) {
        guard isLoaded, let id, ChannelID.isValid(id) else { return }
        if ids.contains(id) {
            unsubscribe(id)
        } else if let name = name.flatMap({ $0.isEmpty ? nil : $0 }) {
            subscribe(Channel(id: id, name: name, thumbnailURL: thumbnail ?? channels.first { $0.id == id }?.thumbnailURL,
                              subscribedAt: .now))
        }
    }

    /// Drops the channels unsubscribed this session from the list.
    func prune() {
        channels.removeAll { !ids.contains($0.id) }
    }

    private func subscribe(_ channel: Channel) {
        ids.insert(channel.id)
        ChannelAvatars.shared.add([channel])
        if !channels.contains(where: { $0.id == channel.id }) {
            let i = channels.firstIndex { $0.name.localizedCaseInsensitiveCompare(channel.name) == .orderedDescending }
            channels.insert(channel, at: i ?? channels.count)
        }
        let store = store
        Task {
            do {
                try await Task.detached { try store.upsert([channel]) }.value
                onNotice?("Subscribed to \(channel.name)")
                onChange?()
            } catch {
                ids.remove(channel.id)
                onNotice?("Couldn't subscribe: \(error.localizedDescription)")
            }
        }
    }

    private func unsubscribe(_ id: String) {
        ids.remove(id)
        let name = channels.first { $0.id == id }?.name ?? "the channel"
        let store = store
        Task {
            do {
                try await Task.detached { try store.unsubscribe(channelId: id) }.value
                onNotice?("Unsubscribed from \(name) · D to undo")
                onChange?()
            } catch {
                ids.insert(id)
                onNotice?("Couldn't unsubscribe: \(error.localizedDescription)")
            }
        }
    }
}

/// Subscribed channels' avatars by channel ID, for a video row with no DeArrow thumbnail. A shared instance so table
/// rows, which are hosted outside the SwiftUI environment, can read it; observed, so rows drawn before it filled update.
@MainActor @Observable
final class ChannelAvatars {
    static let shared = ChannelAvatars()
    private(set) var urls: [String: URL] = [:]

    func add(_ channels: [Channel]) {
        for c in channels where urls[c.id] != c.thumbnailURL {
            if let url = c.thumbnailURL { urls[c.id] = url }
        }
    }
}
