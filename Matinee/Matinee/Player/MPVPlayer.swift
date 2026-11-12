import AppKit
import CMpv
import MatineeKit

/// One libmpv instance with its view. Events are drained on the main thread; callbacks are delivered there too.
/// The owner never reuses the instance after `shutdown()`.
///
/// Two renderers: Metal (mpv's own `gpu-next` VO through MoltenVK, drawing into `view` via `--wid`; needs the patched
/// libmpv from Scripts/build_mpv.sh) and OpenGL (the render API into `MPVGLView`, for a stock libmpv).
/// Calls into mpv from here don't wait for mpv's core: with `--wid`, mpv's VO thread waits on the main thread
/// (`DispatchQueue.main.sync` in its mac code) while the core may wait on the VO, so a blocking call on main could deadlock.
final class MPVPlayer {
    /// The options every mpv handle in the app is created with (the renderer adds its own).
    static let options: [String: String] = [
        "hwdec": "videotoolbox", "ytdl": "no", "cache": "yes",
        // Enough to keep most of a video (1 GiB is ~7 min of 4K VP9 at 20 Mbit/s) without letting two long 4K
        // videos hold 8 GiB each. A seek past what's kept refetches through RangedStream, which is fast.
        "demuxer-max-bytes": "1GiB", "demuxer-max-back-bytes": "512MiB",
        "keep-open": "yes", "terminal": "no", "input-default-bindings": "no", "input-vo-keyboard": "no", "osc": "no",
        // Streams mpv opens itself (live HLS; videos go through RangedStream and URLSession) are fetched by FFmpeg,
        // which mpv tells not to check certificates unless asked. /etc/ssl/cert.pem is macOS's system CA bundle.
        "tls-verify": "yes", "tls-ca-file": "/etc/ssl/cert.pem",
    ]

    private enum Observed: UInt64 { case timePos = 1, duration, pause, eofReached, volume, speed, pausedForCache }

    /// Whether the bundled libmpv is the patched one (Scripts/build_mpv.sh writes the marker).
    static let metalAvailable: Bool = {
        guard let mpv = Bundle.main.url(forResource: "Mpv", withExtension: "bundle") else { return false }
        return FileManager.default.fileExists(atPath: mpv.appending(path: "macvk-wid").path)
    }()

    /// Decided once, at the first player: Metal when available, not switched off in Settings, and MoltenVK is set up
    /// (otherwise no video would appear, so OpenGL is used).
    static let usesMetal: Bool = metalAvailable && !UserDefaults.standard.bool(forKey: "openglPlayback") && MoltenVK.configure()

    private let handle: OpaquePointer
    /// What the window shows: mpv's host view (Metal) or the OpenGL view.
    let view: NSView
    private let glView: MPVGLView?
    /// Metal: the first playback restart after a file loads is its first frame on screen.
    private var waitingForFirstFrame = false
    /// Latest observed values, so nothing has to ask mpv synchronously.
    private var position = 0.0
    private var speed = 1.0
    private var nextReply: UInt64 = 1
    private var frameRequests: [UInt64: CheckedContinuation<CGImage?, Never>] = [:]
    /// Weakly references the player, so a main-queue hop queued by mpv's wakeup after shutdown does nothing.
    private var wakeBox: Unmanaged<WakeBox>?
    /// Serves mpv's `matinee-yt://` streams; retained for mpv until shutdown destroys the handle.
    private let streams: StreamRegistry
    private var streamsRef: Unmanaged<StreamRegistry>?
    private var lastTimeReport = ContinuousClock.Instant.now - .seconds(1)
    private var lastLog = ""
    /// While a seek is in flight, time-pos still reports the old position; it is not forwarded.
    private var seeks = SeekCoalescer()

    var onTime: ((_ position: Double, _ duration: Double?) -> Void)?
    var onPause: ((Bool) -> Void)?
    var onVolume: ((Double) -> Void)?
    var onSpeed: ((Double) -> Void)?
    var onBuffering: ((Bool) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onFileLoaded: (() -> Void)?
    var onEndOfFile: (() -> Void)?
    /// The current load's stream fetch failure, if any.
    var streamFailure: String? { streams.failure }
    var onLoadError: ((String) -> Void)?
    private var duration: Double?

    /// `streamFetch` is what the ranged streams fetch with (StreamWarmer's, so prefetched first bytes are used).
    init(streamFetch: @escaping RangedStream.Fetch = RangedStream.urlSession) {
        streams = StreamRegistry(fetch: streamFetch)
        handle = mpv_create()!
        var options = Self.options
        let host = NSView(frame: .zero)
        if Self.usesMetal {
            // mpv adds its Metal view inside `host`, which this player keeps alive until mpv is destroyed.
            // The player stays in the window while dismissed, so mpv must never hide the cursor.
            options["cursor-autohide"] = "no"
            options["vo"] = "gpu-next"
            options["gpu-api"] = "vulkan"
            options["gpu-context"] = "macvk"
            options["wid"] = String(Int(bitPattern: Unmanaged.passUnretained(host).toOpaque()))
        } else {
            options["vo"] = "libmpv"
        }
        for (name, value) in options { Self.check(mpv_set_option_string(handle, name, value), name) }
        Self.check(mpv_initialize(handle), "initialize")
        mpv_request_log_messages(handle, "warn")
        let ref = Unmanaged.passRetained(streams)
        streamsRef = ref
        Self.check(mpv_stream_cb_add_ro(handle, StreamRegistry.scheme, ref.toOpaque(), Self.openStream), "stream_cb_add_ro")
        mpv_observe_property(handle, Observed.timePos.rawValue, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Observed.duration.rawValue, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Observed.pause.rawValue, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Observed.eofReached.rawValue, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, Observed.volume.rawValue, "volume", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Observed.speed.rawValue, "speed", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, Observed.pausedForCache.rawValue, "paused-for-cache", MPV_FORMAT_FLAG)
        if Self.usesMetal {
            view = host
            glView = nil
        } else {
            let gl = MPVGLView(frame: .zero, mpv: handle)
            view = gl
            glView = gl
        }
        glView?.firstFrame = { [weak self] in self?.onFirstFrame?() }
        let box = Unmanaged.passRetained(WakeBox(player: self))
        wakeBox = box
        mpv_set_wakeup_callback(handle, Self.wakeup, box.toOpaque())
    }

    isolated deinit { shutdown() }

    /// Unsets the wakeup callback, frees the render context, then destroys the handle. Safe to call twice.
    func shutdown() {
        guard let box = wakeBox else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        wakeBox = nil
        glView?.teardown()
        for request in frameRequests.values { request.resume(returning: nil) }
        frameRequests = [:]
        let doomed = Doomed(handle: handle, wake: box, streams: streamsRef, host: Unmanaged.passRetained(view))
        streamsRef = nil
        guard Self.usesMetal else {
            doomed.destroy()
            doomed.host.release()
            return
        }
        // mpv's VO removes its view on the main thread while being destroyed, so main must not wait for it. The host
        // view stays alive until then, and is released back on main.
        DispatchQueue.global(qos: .userInitiated).async {
            doomed.destroy()
            DispatchQueue.main.async { doomed.host.release() }
        }
    }

    // MARK: Control

    /// googlevideo media URLs go through the registry, which fetches them in ranged chunks with the resolved headers;
    /// anything else (HLS manifests) is opened by mpv itself with those headers.
    func load(_ r: Resolved, start: Double) {
        lastLog = ""
        seeks.reset()
        let plan = MPVLoadPlan(r, start: start, streams: MPVLoadPlan.usesRangedStream(r) ? streams.register(r) : nil)
        command(["change-list", "http-header-fields", "clr", ""])
        for field in plan.headerFields { command(["change-list", "http-header-fields", "append", field]) }
        if let ua = plan.userAgent { setProperty("user-agent", ua) }
        command(plan.loadfile)
    }

    func perform(_ c: PlayerCommand) {
        switch c {
        case .togglePause: command(["cycle", "pause"])
        case .seek(let s):
            issue(seeks.request(by: Double(s), from: position, duration: duration, exact: true))
        case .volume(let v): command(["add", "volume", String(v)])
        case .speedStep(let n):
            set(speed: min(max(speed + Double(n) * 0.25, 0.25), 4.0))
        case .fullscreen, .exitFullscreen, .close, .next, .previous, .openChannel, .quality, .subtitles, .audio, .undoSkip, .saveOffline, .toggleComments, .toggleSubscription, .stop: break
        }
    }

    /// The frame on screen as an image (for Live Text). Metal: mpv's `screenshot-raw`, which gpu-next renders on the
    /// GPU, so hardware-decoded frames work (through the render API mpv can't screenshot them). OpenGL: re-rendered.
    func currentFrame() async -> CGImage? {
        if let glView { return glView.snapshot() }
        let id = nextReply
        nextReply += 1
        return await withCheckedContinuation { continuation in
            frameRequests[id] = continuation
            if command(["screenshot-raw", "video"], reply: id) < 0 {
                frameRequests.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    func pause() { setProperty("pause", "yes") }
    func play() { setProperty("pause", "no") }
    /// A saved download: a local file, so no headers and nothing for the stream registry.
    func loadFile(_ url: URL, start: Double) {
        lastLog = ""
        seeks.reset()
        streams.clear()
        command(["change-list", "http-header-fields", "clr", ""])
        var args = ["loadfile", url.path, "replace", "-1"]
        if start > 0 { args.append("start=" + String(format: "%.1f", start)) }
        command(args)
    }

    /// Shows a subtitle file in place of any shown before; a new load drops it, so it is added again after each.
    /// (Not `sub-remove` first: with nothing to remove it fails, and its log line would read as the next load's error.)
    func showSubtitles(_ file: URL) { command(["sub-add", file.path, "select"]) }

    func hideSubtitles() { setProperty("sid", "no") }

    func stop() { command(["stop"]) }
    func seek(to seconds: Double) { issue(seeks.request(to: seconds, duration: duration, exact: false)) }

    /// Shows the target at once; exact seeks decode from the previous keyframe up to it, others land on the keyframe.
    private func issue(_ seek: SeekCoalescer.Seek?) {
        if let target = seeks.target { onTime?(target, duration) }
        guard let seek else { return }
        // A seek that fails (e.g. "Cannot seek in this stream") never restarts playback: its error reply ends it,
        // or position updates would stay frozen and every later seek would queue behind it.
        command(["seek", String(seek.seconds), seek.exact ? "absolute+exact" : "absolute"], reply: Self.seekReply)
    }

    func set(volume: Double) { setProperty("volume", String(volume)) }
    func set(speed: Double) { setProperty("speed", String(speed)) }

    /// Reply id of seeks; frame requests count up from 1.
    private static let seekReply = UInt64.max

    /// Queued to mpv's core, in order; `reply` 0 ignores the result. Negative: mpv refused it at once.
    @discardableResult private func command(_ args: [String], reply: UInt64 = 0) -> Int32 {
        var cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        return cargs.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                let rc = mpv_command_async(handle, reply, $0)
                Self.check(rc, args[0])
                return rc
            }
        }
    }

    private func setProperty(_ name: String, _ value: String) {
        var cvalue: UnsafeMutablePointer<CChar>? = strdup(value)
        defer { free(cvalue) }
        Self.check(mpv_set_property_async(handle, 0, name, MPV_FORMAT_STRING, &cvalue), name)
    }

    private static func check(_ rc: Int32, _ what: String) {
        if rc < 0 { NSLog("mpv error %@: %@", what, String(cString: mpv_error_string(rc))) }
    }

    // MARK: Events

    private nonisolated static let wakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        // The box outlives this call (shutdown releases it after unsetting the callback), and the block retains it.
        let box = Unmanaged<WakeBox>.fromOpaque(ctx!).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.player?.drainEvents() }
        }
    }

    // MARK: Streams (called on mpv's threads)

    /// Opens a `matinee-yt://` URL of the current load; the cookie retains the stream until mpv closes it.
    private nonisolated static let openStream: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<mpv_stream_cb_info>?) -> Int32 = { ctx, uri, info in
        // The registry outlives the handle (shutdown releases it after mpv_terminate_destroy).
        let registry = Unmanaged<StreamRegistry>.fromOpaque(ctx!).takeUnretainedValue()
        guard let uri, let info, let opened = registry.open(String(cString: uri)) else { return MPV_ERROR_LOADING_FAILED.rawValue }
        info.pointee.cookie = Unmanaged.passRetained(opened).toOpaque()
        info.pointee.read_fn = { cookie, buf, n in Int64(MPVPlayer.stream(cookie).read(into: buf!, count: Int(n))) }
        info.pointee.seek_fn = { cookie, offset in MPVPlayer.stream(cookie).seek(to: offset) ? offset : Int64(MPV_ERROR_GENERIC.rawValue) }
        info.pointee.size_fn = { cookie in MPVPlayer.stream(cookie).size() ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue) }
        info.pointee.cancel_fn = { cookie in MPVPlayer.stream(cookie).cancel() }
        // The registry also holds the stream, which outlives this release: mpv may still call cancel_fn after close_fn.
        info.pointee.close_fn = { cookie in
            MPVPlayer.stream(cookie).cancel()
            Unmanaged<RangedStream>.fromOpaque(cookie!).release()
        }
        return 0
    }

    private nonisolated static func stream(_ cookie: UnsafeMutableRawPointer?) -> RangedStream {
        Unmanaged<RangedStream>.fromOpaque(cookie!).takeUnretainedValue()
    }

    private func drainEvents() {
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED:
                glView?.fileLoaded()
                waitingForFirstFrame = glView == nil
                onFileLoaded?()
            case MPV_EVENT_PLAYBACK_RESTART:
                if waitingForFirstFrame {
                    waitingForFirstFrame = false
                    onFirstFrame?()
                }
                issue(seeks.restarted())
            case MPV_EVENT_COMMAND_REPLY where event.pointee.reply_userdata == Self.seekReply:
                if event.pointee.error < 0 { issue(seeks.restarted()) }   // as if it landed: send any queued seek
            case MPV_EVENT_COMMAND_REPLY:
                guard let request = frameRequests.removeValue(forKey: event.pointee.reply_userdata) else { break }
                let reply = event.pointee.data.assumingMemoryBound(to: mpv_event_command.self).pointee
                request.resume(returning: event.pointee.error < 0 ? nil : Self.image(from: reply.result))
            case MPV_EVENT_LOG_MESSAGE:
                let m = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                lastLog = String(cString: m.text)
            case MPV_EVENT_END_FILE:
                let end = event.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                seeks.reset()
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    // The stream failure (or log line) carries the HTTP status, which the error code alone does not.
                    onLoadError?("\(String(cString: mpv_error_string(end.error))) \(streams.failure ?? lastLog)".trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                let p = event.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                propertyChanged(Observed(rawValue: event.pointee.reply_userdata), p)
            default: break
            }
        }
    }

    private func propertyChanged(_ which: Observed?, _ p: mpv_event_property) {
        guard let which else { return }
        let value = p.format == MPV_FORMAT_NONE ? nil : p.data
        switch which {
        case .duration:
            duration = value?.assumingMemoryBound(to: Double.self).pointee
        case .timePos:
            guard let position = value?.assumingMemoryBound(to: Double.self).pointee else { return }
            self.position = position
            guard !seeks.isSeeking else { return }
            let now = ContinuousClock.now
            guard now - lastTimeReport >= .milliseconds(250) else { return }
            lastTimeReport = now
            onTime?(position, duration)
        case .pause:
            if let paused = value?.assumingMemoryBound(to: Int32.self).pointee { onPause?(paused != 0) }
        case .volume:
            if let v = value?.assumingMemoryBound(to: Double.self).pointee { onVolume?(v) }
        case .speed:
            if let v = value?.assumingMemoryBound(to: Double.self).pointee {
                speed = v
                onSpeed?(v)
            }
        case .pausedForCache:
            if let waiting = value?.assumingMemoryBound(to: Int32.self).pointee { onBuffering?(waiting != 0) }
        case .eofReached:
            if let eof = value?.assumingMemoryBound(to: Int32.self).pointee, eof != 0 { onEndOfFile?() }
        }
    }
}

extension MPVPlayer {
    /// `screenshot-raw`'s result: a map with w, h, stride, format ("bgr0" by default) and data.
    fileprivate static func image(from node: mpv_node) -> CGImage? {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list?.pointee else { return nil }
        var w = 0, h = 0, stride = 0, format = "", bytes: mpv_byte_array?
        for i in 0..<Int(list.num) {
            let key = String(cString: list.keys[i]!), value = list.values[i]
            switch (key, value.format) {
            case ("w", MPV_FORMAT_INT64): w = Int(value.u.int64)
            case ("h", MPV_FORMAT_INT64): h = Int(value.u.int64)
            case ("stride", MPV_FORMAT_INT64): stride = Int(value.u.int64)
            case ("format", MPV_FORMAT_STRING): format = String(cString: value.u.string)
            case ("data", MPV_FORMAT_BYTE_ARRAY): bytes = value.u.ba?.pointee
            default: break
            }
        }
        guard format == "bgr0", w > 0, h > 0, stride >= w * 4, let bytes, let base = bytes.data, bytes.size >= stride * h,
              let provider = CGDataProvider(data: Data(bytes: base, count: stride * h) as CFData) else { return nil }
        // bgr0: B, G, R, unused per pixel, i.e. a little-endian 32-bit word with the unused byte first.
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// What `shutdown` hands to the thread that destroys mpv.
private nonisolated final class Doomed: @unchecked Sendable {
    let handle: OpaquePointer
    let wake: Unmanaged<WakeBox>
    let streams: Unmanaged<StreamRegistry>?
    /// Keeps mpv's host view alive until mpv is gone; released on the main thread.
    let host: Unmanaged<NSView>

    init(handle: OpaquePointer, wake: Unmanaged<WakeBox>, streams: Unmanaged<StreamRegistry>?, host: Unmanaged<NSView>) {
        self.handle = handle
        self.wake = wake
        self.streams = streams
        self.host = host
    }

    func destroy() {
        mpv_terminate_destroy(handle)
        wake.release()
        streams?.release()
    }
}

private final class WakeBox: @unchecked Sendable {
    /// Only read on the main thread.
    weak var player: MPVPlayer?
    init(player: MPVPlayer) { self.player = player }
}
