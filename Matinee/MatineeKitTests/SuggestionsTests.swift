import Foundation
import Testing
import MatineeKit

private func service(returning body: String, record: @escaping @Sendable (URL) -> Void = { _ in }) -> SuggestionService {
    SuggestionService { url in
        record(url)
        return Data(body.utf8)
    }
}

@Test func parsesFirefoxFormat() async throws {
    let s = service(returning: #"["swift",["swift tutorial","swift ui"]]"#)
    #expect(try await s.suggestions(for: "swift") == ["swift tutorial", "swift ui"])
}

@Test func capsAtTenSuggestions() async throws {
    let list = (1...15).map { "\"s\($0)\"" }.joined(separator: ",")
    let s = service(returning: "[\"q\",[\(list)]]")
    #expect(try await s.suggestions(for: "q").count == 10)
}

@Test func encodesQuery() async throws {
    let seen = Box<URL?>(nil)
    let s = service(returning: #"["q",[]]"#) { seen.value = $0 }
    _ = try await s.suggestions(for: "c++ & rust")
    #expect(seen.value?.query(percentEncoded: true) == "client=firefox&ds=yt&q=c%2B%2B%20%26%20rust")
    #expect(seen.value?.host() == "suggestqueries.google.com")
}

@Test func emptyQueryNoFetch() async throws {
    let calls = Box<Int>(0)
    let s = service(returning: "[]") { _ in calls.value += 1 }
    #expect(try await s.suggestions(for: "") == [])
    #expect(calls.value == 0)
}

@Test func malformedResponseThrows() async {
    let s = service(returning: #"{"not":"an array"}"#)
    await #expect(throws: (any Error).self) { try await s.suggestions(for: "x") }
}

@Test func lateSuggestionsAfterSubmitAreIgnored() {
    var gate = SuggestionGate()
    let token = gate.begin()
    gate.submit()
    #expect(!gate.accepts(token))
}

@Test func olderTokenIgnored() {
    var gate = SuggestionGate()
    let first = gate.begin()
    let second = gate.begin()
    #expect(!gate.accepts(first))
    #expect(gate.accepts(second))
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
