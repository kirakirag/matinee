import Foundation

/// Keeps `~/.config/matinee/settings.json` and the app's settings (UserDefaults) the same both ways: a change in
/// Settings rewrites the file, and an edit to the file (by hand or by an agent) is applied at once. At launch the
/// file wins, then it is rewritten in full, so a file with only some keys gets the rest.
/// The sandbox reaches that folder through one home-relative exception in the entitlements.
@MainActor public final class SettingsSync {
    public static let url: URL = {
        // In the sandbox, the home directory APIs point into the container; the exception is for the real home.
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(filePath: home).appending(path: ".config/matinee/settings.json")
    }()

    private let url: URL
    private let defaults: UserDefaults
    private let onNotice: (String) -> Void
    /// What the file held after the last read or write, so the app's own writes aren't read back as edits.
    private var known: Data?
    private var applying = false
    private var observer: (any NSObjectProtocol)?
    private var folderSource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?

    public init(url: URL = SettingsSync.url, defaults: UserDefaults = .standard, onNotice: @escaping (String) -> Void) {
        self.url = url
        self.defaults = defaults
        self.onNotice = onNotice
    }

    public func start() {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            onNotice("Can't create \(folder.path): settings aren't saved to a file")
            return
        }
        readFile()
        writeFile()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
        // Editors save by replacing the file, which shows on the folder; writing in place shows on the file.
        folderSource = watch(folder, events: .write)
        watchFile()
    }

    private func defaultsChanged() {
        guard !applying else { return }
        // An edit not picked up yet goes in first, so it isn't overwritten.
        if let onDisk = try? Data(contentsOf: url), onDisk != known { readFile() }
        writeFile()
    }

    private func fileEvent() {
        watchFile()   // a replaced file is a new inode
        guard let onDisk = try? Data(contentsOf: url), onDisk != known else { return }
        readFile()
        writeFile()
    }

    /// Applies the file to the settings. A file that isn't valid JSON is left as it is for the next save.
    private func readFile() {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        known = data
        applying = true
        defer { applying = false }
        do {
            let skipped = try SettingsFile.apply(data, to: defaults)
            if !skipped.isEmpty { onNotice("settings.json: ignored \(skipped.joined(separator: ", "))") }
        } catch {
            onNotice("settings.json isn't valid JSON; nothing was changed")
        }
    }

    /// Writes every setting, unless the file already says exactly that or isn't valid JSON (an edit to fix, not lose).
    private func writeFile() {
        let onDisk = try? Data(contentsOf: url)
        if let onDisk, !onDisk.isEmpty, (try? JSONSerialization.jsonObject(with: onDisk)) == nil { return }
        var data = SettingsFile.json(from: defaults)
        data.append(0x0A)
        guard data != onDisk else { known = data; return }
        do {
            try data.write(to: url, options: .atomic)
            known = data
        } catch {
            onNotice("Can't write \(url.path)")
        }
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = watch(url, events: [.write, .extend, .delete, .rename])
    }

    private func watch(_ target: URL, events: DispatchSource.FileSystemEvent) -> (any DispatchSourceFileSystemObject)? {
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.fileEvent() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
