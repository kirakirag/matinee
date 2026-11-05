import Foundation
import MatineeKit

// One-time import of FreeTube's subscriptions and watch history into Matinee's database.
// Reads only a copy of FreeTube's data folder, never the live one.

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: matinee-import <copied FreeTube dir> <db path>\n".utf8))
    exit(2)
}
let source = URL(filePath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
guard !source.path.contains("/Library/Application Support/FreeTube") else {
    FileHandle.standardError.write(Data("refusing to read FreeTube's live folder; copy it first\n".utf8))
    exit(2)
}

do {
    let profiles = try Data(contentsOf: source.appending(path: "profiles.db"))
    let history = try Data(contentsOf: source.appending(path: "history.db"))
    let store = try Store(path: URL(filePath: args[2]))
    let report = try FreeTubeImport.run(profiles: profiles, history: history, into: store)
    let counts = try store.counts()
    print("report: channels=\(report.channels) history=\(report.history) skippedHistory=\(report.skippedHistory) badLines=\(report.badLines)")
    print("store:  channels=\(counts.channels) history=\(counts.history)")
} catch {
    FileHandle.standardError.write(Data("import failed: \(error)\n".utf8))
    exit(1)
}
