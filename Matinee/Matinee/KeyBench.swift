import AppKit
import MatineeKit
import os

/// `-keybench YES`: replays real key presses through the event queue and measures, per press, the time
/// from posting the event to the first display-link frame after the main thread has handled it.
/// Prints one `KEYBENCH {...}` line (milliseconds) and quits.
final class KeyBench: NSObject {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "keybench") }

    /// An in-memory store with 20,000 synthetic history rows.
    static func seededStore() throws -> Store {
        let store = try Store.inMemory()
        let words = ["lofi", "beats", "chess", "rust", "swift", "piano", "café", "review", "live", "tutorial"]
        try store.upsert((0..<20_000).map { i in
            HistoryEntry(videoId: String(format: "bench%06d", i), title: "\(words[i % 10]) \(words[(i / 10) % 10]) #\(i)",
                         channelId: nil, channelName: "Channel \(i % 300)", lengthSeconds: 600,
                         publishedAt: nil, watchedAt: Date(timeIntervalSinceNow: -Double(i) * 600), positionSeconds: Double(i % 600))
        })
        // 30 subscribed channels with 20 videos each.
        let channels = (0..<30).map { Channel(id: String(format: "UCbench%017d", $0), name: "Feed channel \($0)", thumbnailURL: nil, subscribedAt: .now) }
        try store.upsert(channels)
        for (c, channel) in channels.enumerated() {
            try store.replaceFeed(channelId: channel.id, videos: (0..<20).map { j in
                let i = c * 20 + j
                return FeedVideo(videoId: String(format: "feed%07d", i), channelId: channel.id, channelName: channel.name,
                                 title: "\(words[i % 10]) \(words[(i / 10) % 10]) feed #\(i)",
                                 publishedAt: Date(timeIntervalSinceNow: -Double(i) * 3600), views: nil)
            }, fetchedAt: .now)
        }
        return store
    }

    private struct Pending { let posted: CFTimeInterval; var started: CFTimeInterval? = nil; var handled: CFTimeInterval? = nil; let state: OSSignpostIntervalState }

    private let nav: Navigator
    private let signposter = OSSignposter(subsystem: "local.kirakirag.matinee", category: "KeyBench")
    private var pending: [Int: Pending] = [:]
    private var samples: [Int: Double] = [:]
    private var handleMs: [Int: Double] = [:]
    private var monitor: Any?
    private var link: CADisplayLink?

    init(nav: Navigator) { self.nav = nav }

    func run() async {
        try? await Task.sleep(for: .seconds(1.5))   // let launch settle
        NSApp.activate()
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else {
            print("KEYBENCH {\"error\":\"no window\"}"); NSApp.terminate(nil); return
        }
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == 0x4B42 else { return event }   // "KB"
            if event.data2 == 0 { self?.pending[event.data1]?.started = CACurrentMediaTime() } else { self?.pending[event.data1]?.handled = CACurrentMediaTime() }
            return nil
        }
        link = window.contentView?.displayLink(target: self, selector: #selector(frame(_:)))
        link?.add(to: .main, forMode: .common)

        let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]
        var n = 0
        for i in 0..<120 {
            post(key: "\(i % 6 + 1)", keyCode: digitKeyCodes[i % 6], flags: .command, window: window, id: n); n += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
        let switchCount = n
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        var arrowRanges: [(String, Range<Int>)] = []
        for section in [AppSection.history, .subscriptions] {
            nav.perform(.section(section))
            try? await Task.sleep(for: .milliseconds(500))
            let start = n
            for _ in 0..<300 {
                post(key: down, keyCode: 125, flags: [.numericPad, .function], window: window, id: n); n += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
            arrowRanges.append((section == .history ? "arrow" : "feedArrow", start..<n))
        }
        try? await Task.sleep(for: .milliseconds(300))
        link?.invalidate()

        let fps = NSScreen.main?.maximumFramesPerSecond ?? 60
        let switches = (0..<switchCount).compactMap { samples[$0] }
        let switchHandle = (0..<switchCount).compactMap { handleMs[$0] }
        var line = "KEYBENCH {\"fps\":\(fps),\"switch\":\(Self.stats(switches, of: switchCount)),"
            + "\"switchHandle\":\(Self.stats(switchHandle, of: switchCount))"
        for (name, range) in arrowRanges {
            line += ",\"\(name)\":\(Self.stats(range.compactMap { samples[$0] }, of: range.count))"
                + ",\"\(name)Handle\":\(Self.stats(range.compactMap { handleMs[$0] }, of: range.count))"
        }
        print(line + "}")
        print("KEYBENCH-SLOW", samples.filter { $0.value > 1000.0 / Double(fps) * 2 }.sorted { $0.key < $1.key }.map { "\($0.key):\(Int($0.value))" })
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private func post(key: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, window: NSWindow, id: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: now,
                                           windowNumber: window.windowNumber, context: nil, characters: key,
                                           charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode),
              let marker = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: now,
                                              windowNumber: window.windowNumber, context: nil, subtype: 0x4B42, data1: id, data2: 1),
              let start = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: now,
                                             windowNumber: window.windowNumber, context: nil, subtype: 0x4B42, data1: id, data2: 0)
        else { return }
        pending[id] = Pending(posted: CACurrentMediaTime(), state: signposter.beginInterval("key", id: signposter.makeSignpostID()))
        NSApp.postEvent(start, atStart: false)     // dequeued just before the key event
        NSApp.postEvent(event, atStart: false)
        NSApp.postEvent(marker, atStart: false)   // dequeued only after the key event has been handled
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        for (id, p) in pending { guard let h = p.handled else { continue }
            handleMs[id] = (h - (p.started ?? p.posted)) * 1000
            samples[id] = (now - p.posted) * 1000
            signposter.endInterval("key", p.state)
            pending[id] = nil
        }
    }

    private static func stats(_ ms: [Double], of expected: Int) -> String {
        let s = ms.sorted()
        guard !s.isEmpty else { return "{\"n\":0}" }
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count) * p).rounded(.up)) - 1)] }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        return "{\"n\":\(s.count),\"of\":\(expected),\"p50\":\(f(pct(0.5))),\"p95\":\(f(pct(0.95))),\"max\":\(f(s.last!))}"
    }
}

