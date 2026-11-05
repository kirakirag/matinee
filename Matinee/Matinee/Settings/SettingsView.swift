import MatineeKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let store: Store?
    @State private var importing = false
    @State private var importNote: String?
    @AppStorage("braveProfile") private var braveProfile = ""
    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    /// Max height for new videos; 0 is Best.
    @AppStorage("defaultQuality") private var defaultQuality = 0
    /// Read once at launch by MPVPlayer.usesMetal.
    @AppStorage("openglPlayback") private var openglPlayback = false
    /// Read by PlaybackController.commentsEnabled.
    @AppStorage("showComments") private var showComments = false
    /// Read by ForYouModel.isEnabled and PlaybackController.upNextEnabled.
    @AppStorage("recommendations") private var recommendations = true
    /// Read by LocalModels.isEnabled.
    @AppStorage("localModels") private var localModels = true
    @Environment(LocalModels.self) private var models: LocalModels?

    /// The row the keyboard is on: j/k or ↑/↓ move, Space or Return flips or activates, h/l or ←/→ change a value,
    /// ⌫ on the models row deletes them; Return on the Brave profile edits it, Return or Escape leave the field.
    @State private var selected: Row = .quality
    @FocusState private var keyboard: Bool
    @FocusState private var editingBrave: Bool

    enum Row: Hashable {
        case quality, opengl, dearrowTitles, dearrowThumbnails, comments, recommendations, localModels, models, takeout
        case sponsor(String)
        case brave
    }

    private var rows: [Row] {
        [.quality, .opengl, .dearrowTitles, .dearrowThumbnails, .comments, .recommendations, .localModels, .models, .takeout]
            + SponsorBlock.categories.map { .sponsor($0.id) } + [.brave]
    }

    private func isSelectable(_ row: Row) -> Bool {
        switch row {
        case .opengl: MPVPlayer.metalAvailable
        case .localModels: recommendations
        case .models: models.map { m in m.bytesOnDisk > 0 || modelsAction(m) != nil } ?? false
        case .takeout: store != nil
        default: true
        }
    }

    /// What Return does on the models row: start or retry the download.
    private func modelsAction(_ m: LocalModels) -> (() -> Void)? {
        guard localModels, recommendations else { return nil }
        switch m.state {
        case .absent, .failed: return { m.download() }
        default: return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .focusable()
                .focused($keyboard)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in handle(press) }
                .onAppear { keyboard = true }
                .onChange(of: selected) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selected) } }
        }
    }

    private var form: some View {
        Form {
            Section("Playback") {
                Picker("Default quality", selection: $defaultQuality) {
                    Text("Best").tag(0)
                    ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text("\($0)p").tag($0) }
                }
                .row(.quality, selected)
                Toggle("Use OpenGL instead of Metal", isOn: $openglPlayback)
                    .disabled(!MPVPlayer.metalAvailable)
                    .row(.opengl, selected)
                Text(MPVPlayer.metalAvailable
                     ? "Takes effect after restarting Matinee."
                     : "This build's libmpv can't draw with Metal (run Scripts/build_mpv.sh), so OpenGL is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("DeArrow") {
                Toggle("Use DeArrow titles", isOn: $dearrowTitles).row(.dearrowTitles, selected)
                Toggle("Use DeArrow thumbnails", isOn: $dearrowThumbnails).row(.dearrowThumbnails, selected)
            }
            Section("Comments") {
                Toggle("Show comments in the player", isOn: $showComments).row(.comments, selected)
                Text("O or the speech-bubble button opens a video's comments. They load in the background once a video starts. Read-only: nothing is ever posted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recommendations") {
                Toggle("Up next and For You", isOn: $recommendations).row(.recommendations, selected)
                Text("Up next shows the videos YouTube suggests next to the one playing, from the page Matinee already loads. For You (Y) ranks the suggestions next to your recent history on this Mac: YouTube sees which videos' pages are loaded, never your account or the ranking.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Local AI ranking", isOn: $localModels)
                    .disabled(!recommendations)
                    .row(.localModels, selected)
                Text("Ranks For You with two models that run on this Mac: multilingual-e5 (2.2 GB) reads titles and descriptions, JevK5 (8 GB) checks the top 40. Descriptions of up to 60 videos are read per refresh, one a second. Nothing leaves the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let models { ModelsRow(models: models, enabled: localModels && recommendations).row(.models, selected) }
                HStack {
                    Button("Import YouTube History…") { importing = true }.disabled(store == nil)
                    if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary) }
                }
                .row(.takeout, selected)
                Text("From Google Takeout: takeout.google.com → YouTube and YouTube Music → history, format JSON; unzip and pick watch-history.json. For You learns from it; History stays as it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("SponsorBlock") {
                ForEach(SponsorBlock.categories, id: \.id) { c in
                    SkipToggle(id: c.id, title: c.title, defaultOn: c.defaultOn).row(.sponsor(c.id), selected)
                }
                Text("Skips these segments automatically; U in the player undoes a skip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Open in Brave") {
                TextField("Brave profile", text: $braveProfile, prompt: Text("Default"))
                    .focused($editingBrave)
                    .onSubmit { keyboard = true }
                    .onExitCommand { keyboard = true }
                    .row(.brave, selected)
                Text("Find it in brave://version → Profile Path (e.g. Profile 2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("j/k move · Space flips · h/l change the quality · ⌫ deletes the models")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard let store, case .success(let url) = result else { return }
            importNote = "Importing…"
            Task {
                importNote = await Self.importTakeout(url, into: store)
                keyboard = true
            }
        }
    }

    /// Reads a Takeout watch-history.json off the main thread; the note says what happened.
    private static func importTakeout(_ url: URL, into store: Store) async -> String {
        await Task.detached {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let watches = try TakeoutHistory.parse(Data(contentsOf: url))
                let added = try store.saveImportedWatches(watches)
                return "Imported \(watches.count) videos (\(added) new). For You uses them from its next refresh (⌘R)."
            } catch is TakeoutHistory.NotTakeout {
                return "That isn't a Takeout watch-history.json (choose JSON, not HTML, when exporting)."
            } catch {
                return "Couldn't import: \(error.localizedDescription)"
            }
        }.value
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        let all = rows, i = all.firstIndex(of: selected) ?? 0
        let move = { (step: Int) -> KeyPress.Result in
            var j = i + step
            while all.indices.contains(j), !isSelectable(all[j]) { j += step }
            if all.indices.contains(j) { selected = all[j] }
            return .handled
        }
        switch (press.key, press.characters) {
        case (.downArrow, _), (_, "j"): return move(1)
        case (.upArrow, _), (_, "k"): return move(-1)
        case (.leftArrow, _), (_, "h"): return change(-1)
        case (.rightArrow, _), (_, "l"): return change(1)
        case (.space, _), (.return, _): return activate()
        case (.delete, _):
            guard selected == .models, let models, models.bytesOnDisk > 0 else { return .ignored }
            models.delete()
            return .handled
        default: return .ignored
        }
    }

    /// ←/→ on the quality picker step through the qualities; on a switch they turn it off/on.
    private func change(_ step: Int) -> KeyPress.Result {
        if selected == .quality {
            let q = SettingsFile.qualities, i = q.firstIndex(of: defaultQuality) ?? 0
            defaultQuality = q[min(max(i + step, 0), q.count - 1)]
            return .handled
        }
        guard let value = toggleValue(selected) else { return .ignored }
        if value != (step > 0) { flip(selected) }
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch selected {
        case .quality:
            let q = SettingsFile.qualities
            defaultQuality = q[((q.firstIndex(of: defaultQuality) ?? 0) + 1) % q.count]
        case .models:
            guard let models, let action = modelsAction(models) else { return .ignored }
            action()
        case .brave:
            editingBrave = true
        case .takeout:
            guard store != nil else { return .ignored }
            importing = true
        default:
            flip(selected)
        }
        return .handled
    }

    private func toggleValue(_ row: Row) -> Bool? {
        switch row {
        case .opengl: openglPlayback
        case .dearrowTitles: dearrowTitles
        case .dearrowThumbnails: dearrowThumbnails
        case .comments: showComments
        case .recommendations: recommendations
        case .localModels: localModels
        case .sponsor(let id):
            UserDefaults.standard.object(forKey: "sponsorblock.\(id)") as? Bool
                ?? SponsorBlock.categories.first { $0.id == id }?.defaultOn ?? false
        default: nil
        }
    }

    private func flip(_ row: Row) {
        guard isSelectable(row) else { return }
        switch row {
        case .opengl: openglPlayback.toggle()
        case .dearrowTitles: dearrowTitles.toggle()
        case .dearrowThumbnails: dearrowThumbnails.toggle()
        case .comments: showComments.toggle()
        case .recommendations: recommendations.toggle()
        case .localModels: localModels.toggle()
        case .sponsor(let id): UserDefaults.standard.set(!(toggleValue(row) ?? false), forKey: "sponsorblock.\(id)")
        default: break
        }
    }
}

private extension View {
    /// A settings row the keyboard can select: scrolled to by id, outlined when selected.
    func row(_ row: SettingsView.Row, _ selected: SettingsView.Row) -> some View {
        id(row)
            .padding(.vertical, 2)
            .overlay {
                if row == selected {
                    RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(-4)
                }
            }
    }
}

/// The local models' download: progress, size on disk, and Delete. Turning the setting on starts the download; off
/// stops it (what arrived is kept for next time).
private struct ModelsRow: View {
    let models: LocalModels
    let enabled: Bool

    var body: some View {
        HStack {
            switch models.state {
            case .downloading(let f):
                ProgressView(value: f).frame(maxWidth: 200)
                Text("Downloading \(Int(f * 100))%").font(.caption).monospacedDigit()
            case .ready:
                Text("Models ready").font(.caption)
            case .failed(let e):
                Text("Download failed: \(e)").font(.caption).foregroundStyle(.red)
                Button("Retry") { models.download() }.disabled(!enabled)
            case .absent:
                Text(enabled ? "Not downloaded" : "Not downloaded (turn on to download)").font(.caption)
                if enabled { Button("Download") { models.download() } }
            }
            Spacer()
            if models.bytesOnDisk > 0 {
                Text(ByteCountFormatter.string(fromByteCount: models.bytesOnDisk, countStyle: .file))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Delete Models") { models.delete() }
            }
        }
        .onChange(of: enabled, initial: true) {
            if enabled { if models.state == .absent { models.download() } } else { models.cancel() }
        }
    }
}

/// One SponsorBlock category's switch, stored under `sponsorblock.<id>` as `SponsorBlock.enabledCategories` reads it.
private struct SkipToggle: View {
    let title: String
    @AppStorage private var isOn: Bool

    init(id: String, title: String, defaultOn: Bool) {
        self.title = title
        _isOn = AppStorage(wrappedValue: defaultOn, "sponsorblock.\(id)")
    }

    var body: some View { Toggle(title, isOn: $isOn) }
}
