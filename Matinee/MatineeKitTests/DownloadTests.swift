import Foundation
import SQLite3
import Testing
import MatineeKit

private func download(_ id: String, _ state: Download.State, addedAt: TimeInterval = 1_700_000_000) -> Download {
    Download(videoId: id, title: "T \(id)", channelName: "C", channelId: nil, lengthSeconds: 61, state: state, bytes: nil,
             addedAt: Date(timeIntervalSince1970: addedAt))
}

@Test func downloadRoundTrip() throws {
    let s = try Store.inMemory()
    #expect(try s.downloads().isEmpty)
    var a = download("aaaaaaaaaaa", .queued, addedAt: 1)
    let b = download("bbbbbbbbbbb", .downloading, addedAt: 2)
    try s.upsertDownload(a)
    try s.upsertDownload(b)
    #expect(try s.downloads() == [b, a])   // newest first
    a.state = .done
    a.bytes = 1234
    a.channelId = "UCaaaaaaaaaaaaaaaaaaaaaa"
    try s.upsertDownload(a)
    #expect(try s.download(videoId: "aaaaaaaaaaa") == a)
    try s.removeDownload(videoId: "aaaaaaaaaaa")
    #expect(try s.download(videoId: "aaaaaaaaaaa") == nil)
    #expect(try s.downloads() == [b])
}

@Test func failedDownloadKeepsItsErrorAndRetries() throws {
    let s = try Store.inMemory()
    try s.upsertDownload(download("aaaaaaaaaaa", .failed("Video unavailable")))
    #expect(try s.download(videoId: "aaaaaaaaaaa")?.state == .failed("Video unavailable"))
    #expect(DownloadQueue.requeueInterrupted(try s.downloads()).map(\.state) == [.failed("Video unavailable")])
}

@Test func interruptedDownloadsAreRequeued() {
    let rows = [download("aaaaaaaaaaa", .downloading), download("bbbbbbbbbbb", .queued),
                download("ccccccccccc", .done), download("ddddddddddd", .failed("x"))]
    #expect(DownloadQueue.requeueInterrupted(rows).map(\.state) == [.queued, .queued, .done, .failed("x")])
}

@Test func deleteRemovesEveryFileOfTheVideo() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let id = "aaaaaaaaaaa"
    for name in ["\(id).mp4", "\(id).mp4.part", "\(id).f137.mp4", "\(id).f251.webm.part", "bbbbbbbbbbb.mp4"] {
        FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: Data("x".utf8))
    }
    try DownloadFiles.removeAll(videoId: id, in: dir)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["bbbbbbbbbbb.mp4"])
    try DownloadFiles.removeAll(videoId: id, in: dir)   // nothing left: no error
    #expect(throws: (any Error).self) { try DownloadFiles.removeAll(videoId: "../../etc/x", in: dir) }
}

@Test func downloadFileIsTheVideoIdInMoviesMatinee() {
    #expect(DownloadFiles.directory.path.hasSuffix("/Movies/Matinee"))
    #expect(!DownloadFiles.directory.path.contains("/Library/Containers/"))
    #expect(DownloadFiles.file(videoId: "aaaaaaaaaaa") == DownloadFiles.directory.appending(path: "aaaaaaaaaaa.mp4"))
}

@Test func migratesV4Database() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "v4.sqlite")
    let old = try Store(path: url)   // a current database, rolled back to v4 below
    try old.saveSegments([SponsorSegment(category: "sponsor", start: 1, end: 2, uuid: "u")], videoId: "aaaaaaaaaaa", fetchedAt: .now)
    var h: OpaquePointer?
    #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
    #expect(sqlite3_exec(h, "DROP TABLE download; PRAGMA user_version = 4;", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(h)
    let s = try Store(path: url)
    #expect(try s.segments(videoId: "aaaaaaaaaaa")?.count == 1)
    try s.upsertDownload(download("aaaaaaaaaaa", .queued))
    #expect(try s.downloads().count == 1)
}

@Test func missingFileFallsBackToStreaming() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appending(path: "aaaaaaaaaaa.mp4")
    let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
    let done = download("aaaaaaaaaaa", .done)
    #expect(LocalCopy.file(for: done, in: dir, exists: exists) == nil)   // removed in Finder
    FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
    #expect(LocalCopy.file(for: done, in: dir, exists: exists) == file)
    #expect(LocalCopy.file(for: download("aaaaaaaaaaa", .downloading), in: dir, exists: exists) == nil)
    #expect(LocalCopy.file(for: nil, in: dir, exists: exists) == nil)
    #expect(LocalCopy.file(for: done, exists: { _ in true }) == DownloadFiles.file(videoId: "aaaaaaaaaaa"))
}
