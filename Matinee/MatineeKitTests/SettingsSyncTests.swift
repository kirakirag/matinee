import Foundation
import Testing
import MatineeKit

@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<40 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    return condition()
}

@MainActor @Test func settingsSyncKeepsFileAndDefaultsTheSame() async throws {
    let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "SettingsSyncTests.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "settings.json")
    let suite = "SettingsSyncTests.\(UUID().uuidString)"
    let d = try #require(UserDefaults(suiteName: suite))
    defer { d.removePersistentDomain(forName: suite) }
    var notices: [String] = []

    // At launch a partial file wins and is filled in.
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"defaultQuality": 720}"#.utf8).write(to: url)
    let sync = SettingsSync(url: url, defaults: d) { notices.append($0) }
    sync.start()
    #expect(d.integer(forKey: "defaultQuality") == 720)
    #expect(try Data(contentsOf: url).dropLast() == SettingsFile.json(from: d))

    // A change in the app reaches the file.
    d.set(true, forKey: "showComments")
    #expect(await eventually { (try? String(contentsOf: url, encoding: .utf8))?.contains(#""showComments" : true"#) == true })

    // An edit to the file, written in place or replaced, reaches the settings.
    try Data(#"{"defaultQuality": 1080}"#.utf8).write(to: url)
    #expect(await eventually { d.integer(forKey: "defaultQuality") == 1080 })
    try Data(#"{"defaultQuality": 480, "colour": 1}"#.utf8).write(to: url, options: .atomic)
    #expect(await eventually { d.integer(forKey: "defaultQuality") == 480 })
    #expect(await eventually { notices.contains("settings.json: ignored colour") })
    #expect(await eventually { (try? Data(contentsOf: url))?.dropLast() == SettingsFile.json(from: d) })

    // An edit that isn't valid JSON is left for the next save, even when a setting changes meanwhile.
    let broken = Data(#"{"defaultQuality": 2160"#.utf8)
    try broken.write(to: url)
    #expect(await eventually { notices.contains("settings.json isn't valid JSON; nothing was changed") })
    d.set(false, forKey: "showComments")
    try? await Task.sleep(for: .milliseconds(300))
    #expect(try Data(contentsOf: url) == broken)
    #expect(d.integer(forKey: "defaultQuality") == 480)
}
