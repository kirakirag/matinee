import MatineeKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let store: Store?
    @Environment(Subscriptions.self) private var subscriptions: Subscriptions?
    @Environment(Navigator.self) private var nav
    /// Which Takeout file the open picker is for.
    @State private var importing: TakeoutFile?
    @State private var importNote: String?
    @State private var subscriptionsNote: String?
    @AppStorage("braveProfile") private var braveProfile = ""
    @AppStorage("dearrowTitles") private var dearrowTitles = true
    @AppStorage("dearrowThumbnails") private var dearrowThumbnails = true
    /// Max height for new videos; 0 is Best.
    @AppStorage("defaultQuality") private var defaultQuality = 0
    /// Read once at launch by MPVPlayer.usesMetal.
    @AppStorage("openglPlayback") private var openglPlayback = false
    /// Read by HeadGestureService.isSwitchedOn. Only on once calibrated: switching it on first opens the calibration.
    @AppStorage("headGestures") private var headGestures = false
    @Environment(HeadGestureService.self) private var head: HeadGestureService?
    @State private var calibrating = false
    @State private var confirmingReset = false
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
    @FocusState private var editingBrave: Bool

    enum TakeoutFile { case history, subscriptions }

    enum Row: Hashable {
        case quality, opengl, headGestures, headSetup, headReset, dearrowTitles, dearrowThumbnails, comments, subscriptions
        case recommendations, localModels, models
        case takeout
        case sponsor(String)
        case brave
    }

    private var rows: [Row] {
        [.quality, .opengl, .headGestures, .headSetup, .headReset, .dearrowTitles, .dearrowThumbnails, .comments, .subscriptions,
         .recommendations, .localModels, .models, .takeout]
            + SponsorBlock.categories.map { .sponsor($0.id) } + [.brave]
    }

    private func isSelectable(_ row: Row) -> Bool {
        switch row {
        case .opengl: MPVPlayer.metalAvailable
        case .headGestures: head != nil
        case .headSetup, .headReset: head?.isCalibrated == true
        case .localModels: recommendations
        case .models: models.map { m in m.bytesOnDisk > 0 || modelsAction(m) != nil } ?? false
        case .takeout: store != nil
        case .subscriptions: store != nil && subscriptions != nil
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
                .onChange(of: nav.settingsKeyRequest) { handle(nav.settingsKey) }
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
                     ? "Applies after restart"
                     : "Metal unavailable in this build")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Head gestures with AirPods", isOn: Binding(get: { headGesturesOn }, set: { setHeadGestures($0) }))
                    .disabled(head == nil)
                    .row(.headGestures, selected)
                if head?.isCalibrated == true {
                    Button("Set Up Head Gestures Again…") { calibrating = true }.row(.headSetup, selected)
                    Button("Reset Head Gestures…", role: .destructive) { confirmingReset = true }.row(.headReset, selected)
                }
                Text(HeadGestureService.isDenied
                     ? "Allow in System Settings → Privacy & Security → Motion & Fitness"
                     : "Nod: play/pause · Shake: next · Tilt: seek · ⌘Z: undo")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("DeArrow") {
                Toggle("Use DeArrow titles", isOn: $dearrowTitles).row(.dearrowTitles, selected)
                Toggle("Use DeArrow thumbnails", isOn: $dearrowThumbnails).row(.dearrowThumbnails, selected)
            }
            Section("Comments") {
                Toggle("Show comments in the player", isOn: $showComments).row(.comments, selected)
                Text("O to open comments")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Subscriptions") {
                HStack {
                    Button("Import YouTube Subscriptions…") { importing = .subscriptions }
                        .disabled(store == nil || subscriptions == nil)
                    if let subscriptionsNote { Text(subscriptionsNote).font(.caption).foregroundStyle(.secondary) }
                }
                .row(.subscriptions, selected)
                Text("subscriptions.csv from Google Takeout")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recommendations") {
                Toggle("Up next and For You", isOn: $recommendations).row(.recommendations, selected)
                Text("Y to open For You")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Local AI ranking", isOn: $localModels)
                    .disabled(!recommendations)
                    .row(.localModels, selected)
                if let models { ModelsRow(models: models, enabled: localModels && recommendations).row(.models, selected) }
                HStack {
                    Button("Import YouTube History…") { importing = .history }.disabled(store == nil)
                    if let importNote { Text(importNote).font(.caption).foregroundStyle(.secondary) }
                }
                .row(.takeout, selected)
                Text("watch-history.json from Google Takeout")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("SponsorBlock") {
                ForEach(SponsorBlock.categories, id: \.id) { c in
                    SkipToggle(id: c.id, title: c.title, defaultOn: c.defaultOn).row(.sponsor(c.id), selected)
                }
                Text("U to undo a skip")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Open in Brave") {
                TextField("Brave profile", text: $braveProfile, prompt: Text("Default"))
                    .focused($editingBrave)
                    .onSubmit { editingBrave = false }
                    .onExitCommand { editingBrave = false }
                    .row(.brave, selected)
                Text("From brave://version → Profile Path")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("j/k move · Space flips · h/l change the quality · ⌫ deletes the models")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $calibrating) {
            if let head { HeadGestureCalibrationView().environment(head) }
        }
        .confirmationDialog("Reset head gestures?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { head?.reset() }
        } message: {
            Text("Forgets your calibration and turns head gestures off.")
        }
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .subscriptions ? [.commaSeparatedText] : [.json]) { result in
            let file = importing
            guard let store, case .success(let url) = result else { return }
            if file == .subscriptions, let subscriptions {
                subscriptionsNote = "Importing…"
                Task {
                    subscriptionsNote = await Self.importSubscriptions(url, into: store)
                    await subscriptions.reload()
                }
            } else {
                importNote = "Importing…"
                Task {
                    importNote = await Self.importTakeout(url, into: store)
                }
            }
        }
    }

    /// Reads a Takeout subscriptions.csv off the main thread; the note says what happened.
    private static func importSubscriptions(_ url: URL, into store: Store) async -> String {
        await Task.detached {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let channels = try TakeoutSubscriptions.parse(Data(contentsOf: url))
                let added = try store.addSubscriptions(channels)
                return "Imported \(channels.count) channels (\(added) new)."
            } catch is TakeoutSubscriptions.NotTakeout {
                return "That isn't a Takeout subscriptions.csv."
            } catch {
                return "Couldn't import: \(error.localizedDescription)"
            }
        }.value
    }

    /// Reads a Takeout watch-history.json off the main thread; the note says what happened.
    private static func importTakeout(_ url: URL, into store: Store) async -> String {
        await Task.detached {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let watches = try TakeoutHistory.parse(Data(contentsOf: url))
                let added = try store.saveImportedWatches(watches)
                return "Imported \(watches.count) videos (\(added) new)."
            } catch is TakeoutHistory.NotTakeout {
                return "Not a Takeout watch-history.json (export as JSON)."
            } catch {
                return "Couldn't import: \(error.localizedDescription)"
            }
        }.value
    }

    private func handle(_ key: SettingsKey) {
        switch key {
        case .down: move(1)
        case .up: move(-1)
        case .left: change(-1)
        case .right: change(1)
        case .activate: activate()
        case .delete: if selected == .models, let models, models.bytesOnDisk > 0 { models.delete() }
        }
    }

    private func move(_ step: Int) {
        let all = rows
        var j = (all.firstIndex(of: selected) ?? 0) + step
        while all.indices.contains(j), !isSelectable(all[j]) { j += step }
        if all.indices.contains(j) { selected = all[j] }
    }

    /// ←/→ on the quality picker step through the qualities; on a switch they turn it off/on.
    private func change(_ step: Int) {
        if selected == .quality {
            let q = SettingsFile.qualities, i = q.firstIndex(of: defaultQuality) ?? 0
            defaultQuality = q[min(max(i + step, 0), q.count - 1)]
            return
        }
        if let value = toggleValue(selected), value != (step > 0) { flip(selected) }
    }

    private func activate() {
        switch selected {
        case .quality:
            let q = SettingsFile.qualities
            defaultQuality = q[((q.firstIndex(of: defaultQuality) ?? 0) + 1) % q.count]
        case .models:
            guard let models, let action = modelsAction(models) else { return }
            action()
        case .brave:
            editingBrave = true
        case .takeout:
            guard store != nil else { return }
            importing = .history
        case .subscriptions:
            guard store != nil, subscriptions != nil else { return }
            importing = .subscriptions
        case .headSetup:
            calibrating = true
        case .headReset:
            confirmingReset = true
        default:
            flip(selected)
        }
    }

    private var headGesturesOn: Bool { headGestures && head?.isCalibrated == true }

    /// Switching head gestures on before they're set up opens the setup, which switches them on when it's done.
    private func setHeadGestures(_ on: Bool) {
        if on, head?.isCalibrated != true {
            calibrating = head != nil
        } else {
            headGestures = on
        }
    }

    private func toggleValue(_ row: Row) -> Bool? {
        switch row {
        case .opengl: openglPlayback
        case .headGestures: headGesturesOn
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
        case .headGestures: setHeadGestures(!headGesturesOn)
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
                Text(enabled ? "Not downloaded" : "Not downloaded").font(.caption)
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
