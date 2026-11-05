import MatineeKit
import SwiftUI

struct DownloadsView: View {
    let manager: DownloadManager
    let dearrow: DeArrowService
    @Environment(Navigator.self) private var nav
    @Environment(PlaybackController.self) private var player: PlaybackController?

    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    @State private var branding: [String: Branding] = [:]
    /// Finished downloads whose file is gone (e.g. removed in Finder); checked off the main thread.
    @State private var missing: Set<String> = []
    @State private var selection: String?
    @State private var listFocus = 0
    @State private var deleting: Download?

    var body: some View {
        TableList(items: manager.items, selection: $selection, rowHeight: 78, focusRequest: listFocus,
                  onActivate: { activate($0) },
                  contextMenu: [("Copy Link", { nav.copy(YouTubeURL.watchURL(videoId: $0.videoId)) }),
                                ("Delete…", { deleting = $0 })]) { d in
            DownloadRow(download: d, manager: manager, missing: missing.contains(d.videoId),
                        thumbnail: thumbnail(d.videoId))
        }
        .overlay {
            if manager.items.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Press S on a video to save it for offline viewing."))
            }
        }
        .onChange(of: nav.deleteRequest) {
            guard nav.section == .downloads, nav.paths[.downloads]?.isEmpty ?? true,
                  let d = manager.items.first(where: { $0.videoId == selection }) else { return }
            deleting = d
        }
        .onChange(of: nav.copyRequest) {
            guard nav.section == .downloads, nav.paths[.downloads]?.isEmpty ?? true, let selection else { return }
            nav.copy(YouTubeURL.watchURL(videoId: selection))
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { d in
            Button("Delete", role: .destructive) { manager.delete(d.videoId) }.keyboardShortcut(.defaultAction)   // Return
        }
        .onChange(of: deleting) { _, d in if d == nil { listFocus += 1 } }
        .onAppear { listFocus += 1 }
        // Re-checked when the section is entered or a download finishes, not per render.
        .task(id: TaskKey(entered: nav.section == .downloads, done: manager.items.filter { $0.state == .done }.map(\.videoId))) {
            await refresh()
        }
    }

    private struct TaskKey: Equatable { let entered: Bool; let done: [String] }

    private func refresh() async {
        let done = manager.items.filter { $0.state == .done }
        missing = await Task.detached {
            Set(done.filter { LocalCopy.file(for: $0, exists: { FileManager.default.fileExists(atPath: $0.path) }) == nil }.map(\.videoId))
        }.value
        let ids = manager.items.map(\.videoId).filter { branding[$0] == nil }
        guard !ids.isEmpty else { return }
        branding.merge(await dearrow.branding(for: ids)) { $1 }
    }

    /// DeArrow's thumbnail or the placeholder: never YouTube's own.
    private func thumbnail(_ videoId: String) -> URL? {
        guard dearrowThumbnails, let time = branding[videoId]?.thumbnailTime else { return nil }
        return DeArrow.thumbnailURL(videoId: videoId, time: time)
    }

    /// Return plays a finished download (streaming if its file is gone) and retries a failed one.
    private func activate(_ d: Download) {
        switch d.state {
        case .done:
            player?.open(.init(videoId: d.videoId, title: d.title, channelName: d.channelName, channelId: d.channelId,
                               lengthSeconds: d.lengthSeconds, publishedAt: nil, thumbnailURL: thumbnail(d.videoId)))
        case .failed:
            manager.retry(d.videoId)
        case .queued, .downloading:
            break
        }
    }
}

private struct DownloadRow: View {
    let download: Download
    /// Read in this body, so a running download's row redraws as bytes arrive: the table only reloads a row when its
    /// item changes, and progress isn't part of the item.
    let manager: DownloadManager
    let missing: Bool
    let thumbnail: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(videoId: download.videoId, url: thumbnail, channelId: download.channelId).frame(width: 120)
            VStack(alignment: .leading, spacing: 3) {
                Text(download.title.isEmpty ? download.videoId : download.title).font(.body.weight(.medium)).lineLimit(2)
                Text(download.channelName).foregroundStyle(.secondary).lineLimit(1)
                status.font(.caption)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        switch download.state {
        case .queued:
            Text("Queued").foregroundStyle(.tertiary)
        case .downloading:
            if let p = manager.progress[download.videoId] {
                VStack(alignment: .leading, spacing: 2) {
                    if p.stage == .downloading, let fraction = p.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 220)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 220)
                    }
                    Text(DownloadFormat.detail(p)).monospacedDigit().foregroundStyle(.tertiary)
                }
            } else {
                Text("Starting…").foregroundStyle(.tertiary)
            }
        case .done:
            if missing {
                Text("File missing · plays online").foregroundStyle(.orange)
            } else {
                Text(download.bytes.map(DownloadFormat.bytes) ?? "Saved").foregroundStyle(.tertiary)
            }
        case .failed(let message):
            Text(message.isEmpty ? "Failed · ↩ to retry" : "\(message) · ↩ to retry").foregroundStyle(.red).lineLimit(2)
        }
    }
}

/// In the toolbar while something downloads, from any section: the running downloads' progress together, and how
/// many are left. Its own view, so progress redraws only this, not the window's toolbar.
struct DownloadsIndicator: View {
    @Environment(DownloadManager.self) private var manager: DownloadManager?
    @Environment(Navigator.self) private var nav

    var body: some View {
        if let manager, manager.activeCount > 0 {
            Button { nav.perform(.section(.downloads)) } label: {
                HStack(spacing: 5) {
                    if let fraction = manager.overallFraction {
                        ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    }
                    if manager.activeCount > 1 { Text("\(manager.activeCount)").monospacedDigit() }
                }
            }
            .help(help(manager))
        }
    }

    private func help(_ manager: DownloadManager) -> String {
        let count = manager.activeCount == 1 ? "1 download" : "\(manager.activeCount) downloads"
        return manager.overallFraction.map { "\(count) · \(Int($0 * 100))% (T)" } ?? "\(count) (T)"
    }
}
