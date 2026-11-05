import AppKit
import MatineeKit

/// `-workerselftest <video id>`: resolves the video through the bundled worker, inside the app's sandbox,
/// once with yt-dlp's default clients (which need the JS challenge, so Deno must run) and once with
/// `visionos`. Prints one `WORKERSELFTEST {...}` line per run, then quits.
enum WorkerSelfTest {
    static var requestedID: String? { UserDefaults.standard.string(forKey: "workerselftest") }

    static func run(_ id: String) async {
        let worker = WorkerClient.bundled()
        await worker.warmUp()
        for (label, clients) in [("default", nil), ("visionos", ["visionos"])] as [(String, [String]?)] {
            let start = ContinuousClock.now
            var line: [String: Any] = ["run": label]
            do {
                let r = try await worker.resolve(id, clients: clients)
                line.merge(["ok": true, "height": r.height, "vcodec": r.vcodec ?? NSNull(), "jsc": r.jsc ?? NSNull(),
                            "audio": r.audioURL != nil, "wait_s": max(0, r.availableAt?.timeIntervalSinceNow ?? 0)]) { $1 }
            } catch {
                line.merge(["ok": false, "error": "\(error)"]) { $1 }
            }
            line["ms"] = Int((ContinuousClock.now - start) / .milliseconds(1))
            let json = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
            print("WORKERSELFTEST \(json ?? "{}")")
        }
        await worker.shutdown()
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
