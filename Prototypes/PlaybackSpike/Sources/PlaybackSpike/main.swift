// Throwaway prototype: resolve with a yt-dlp worker (child process), play in-window with libmpv, log timings.
// Usage: PlaybackSpike [--client visionos] [--sort vcodec:vp9] [--seconds 8] ID...
import AppKit
import CMpv

// MARK: - Arguments and logging

let argv = CommandLine.arguments
func option(_ name: String) -> String? {
    argv.firstIndex(of: name).flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
}
// Option values (client names, sorts, seconds) never look like an 11-character video ID.
let videoIDs = argv.dropFirst().filter { $0.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil }
let watchSeconds = Double(option("--seconds") ?? "8")!

let launchTime = DispatchTime.now()
var origin = launchTime
func ms(since t: DispatchTime) -> Int { Int((DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000) }
func log(_ event: String) {
    FileHandle.standardError.write("T+\(ms(since: origin)) \(event)\n".data(using: .utf8)!)
}

// MARK: - Resolver child process (JSON lines over stdin/stdout)

final class Resolver {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var lines: [String] = []
    private let lock = NSCondition()

    init() throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: caches.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/opt/yt-dlp/libexec/bin/python")
        var args = ["-I", Bundle.main.path(forResource: "resolve_worker", ofType: "py")!, "--ready"]
        if let c = option("--client") { args += ["--client", c] }
        if let s = option("--sort") { args += ["--sort", s] }
        process.arguments = args
        process.currentDirectoryURL = caches  // Deno needs a readable cwd
        process.environment = [
            "HOME": NSHomeDirectory(), "XDG_CACHE_HOME": caches.path, "DENO_DIR": caches.appendingPathComponent("deno").path,
            "TMPDIR": caches.appendingPathComponent("tmp").path, "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        try process.run()
    }

    private func received(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.broadcast()
        lock.unlock()
    }

    /// Blocks until the next JSON line arrives.
    func nextLine() -> [String: Any] {
        lock.lock()
        while lines.isEmpty { lock.wait() }
        let line = lines.removeFirst()
        lock.unlock()
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? ["error": "bad line: \(line)"]
    }

    func resolve(_ id: String) -> [String: Any] {
        input.fileHandleForWriting.write((id + "\n").data(using: .utf8)!)
        return nextLine()
    }
}

// MARK: - mpv

func check(_ rc: Int32, _ what: String) { if rc < 0 { log("mpv error \(what): \(String(cString: mpv_error_string(rc)))") } }

let mpv = mpv_create()!
for (k, v) in [("vo", "libmpv"), ("hwdec", "videotoolbox"), ("ytdl", "no"), ("cache", "yes"),
               ("demuxer-max-bytes", "50MiB"), ("keep-open", "no"), ("terminal", "no")] {
    check(mpv_set_option_string(mpv, k, v), k)
}
check(mpv_initialize(mpv), "initialize")
mpv_request_log_messages(mpv, "warn")

func command(_ args: [String]) {
    var cargs = args.map { strdup($0) } + [nil]
    defer { cargs.forEach { free($0) } }
    cargs.withUnsafeMutableBufferPointer { buf in
        buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { check(mpv_command(mpv, $0), args[0]) }
    }
}

func property(_ name: String) -> String {
    guard let p = mpv_get_property_string(mpv, name) else { return "-" }
    defer { mpv_free(p) }
    return String(cString: p)
}

let mpvEvents = DispatchQueue(label: "mpv-events")
mpv_set_wakeup_callback(mpv, { _ in
    mpvEvents.async {
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED: log("file-loaded")
            case MPV_EVENT_LOG_MESSAGE:
                let m = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                log("mpv[\(String(cString: m.prefix))] \(String(cString: m.text).trimmingCharacters(in: .newlines))")
            case MPV_EVENT_PLAYBACK_RESTART: log("playback-restart")
            case MPV_EVENT_END_FILE:
                let end = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR { log("end-file error: \(String(cString: mpv_error_string(end.error)))") }
            default: break
            }
        }
    }
}, nil)

// MARK: - App

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
let view = MPVGLView(frame: window.contentView!.bounds, mpv: mpv)
view.autoresizingMask = [.width, .height]
window.contentView!.addSubview(view)
window.title = "PlaybackSpike"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate()

log("sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) home=\(NSHomeDirectory())")

Thread.detachNewThread {
    let resolver: Resolver
    do { resolver = try Resolver() } catch { log("resolver failed to start: \(error)"); exit(2) }
    let ready = resolver.nextLine()
    log("resolver-ready \(ready["ready"] != nil ? "ok" : "\(ready)")")

    for id in videoIDs {
        origin = DispatchTime.now()
        log("start \(id)")
        let r = resolver.resolve(id)
        if let err = r["error"] as? String { log("resolve-error \(err)"); continue }
        let videoURL = r["video_url"] as! String
        let audioURL = r["audio_url"] as? String
        log("resolved height=\(r["height"] ?? 0) vcodec=\(r["vcodec"] ?? "") worker_ms=\(r["ms"] ?? 0)")

        let firstFrame = DispatchSemaphore(value: 0)
        DispatchQueue.main.sync {
            view.onFirstFrame = { log("first-frame"); firstFrame.signal() }
            view.armFirstFrame()
        }
        // googlevideo answers 403 unless the request carries the headers of the client that resolved the URL
        let headers = r["headers"] as? [String: String] ?? [:]
        command(["change-list", "http-header-fields", "clr", ""])
        for (k, v) in headers where k != "User-Agent" { command(["change-list", "http-header-fields", "append", "\(k): \(v)"]) }
        if let ua = headers["User-Agent"] { check(mpv_set_property_string(mpv, "user-agent", ua), "user-agent") }
        log("headers client=\(r["client"] ?? "-") \(headers.keys.sorted())")
        // YouTube makes stream URLs answer 403 until a pre-roll ad's length has passed
        let availableAt = (r["available_at"] as? Double) ?? 0
        let wait = availableAt - Date().timeIntervalSince1970
        if wait > 0 { log("ad-wait \(Int(wait * 1000))ms"); Thread.sleep(forTimeInterval: wait + 0.3) }
        var load = ["loadfile", videoURL, "replace", "-1"]
        // %len% quoting keeps any commas in the URL from splitting the option list
        if let audioURL { load.append("audio-file=%\(audioURL.utf8.count)%\(audioURL)") }
        log("loadfile")
        command(load)
        if firstFrame.wait(timeout: .now() + 30) == .timedOut { log("first-frame TIMEOUT") }
        Thread.sleep(forTimeInterval: watchSeconds)
        log("stats hwdec=\(property("hwdec-current")) codec=\(property("video-codec")) " +
            "size=\(property("width"))x\(property("height")) audio=\(property("audio-codec-name")) " +
            "vo-drops=\(property("frame-drop-count")) dec-drops=\(property("decoder-frame-drop-count"))")
    }
    origin = launchTime
    log("done")
    DispatchQueue.main.async { app.terminate(nil) }
}

app.run()
