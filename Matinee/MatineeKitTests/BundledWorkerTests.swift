import Foundation
import Testing

/// `Runtime.bundle` is built by `Scripts/fetch_runtime.sh` and is not in git, so its copy of the worker
/// goes stale when `Matinee/Worker/matinee_worker.py` changes. Fails until the copy is refreshed.
@Test func bundledWorkerMatchesSource() throws {
    let matinee = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = try Data(contentsOf: matinee.appending(path: "Worker/matinee_worker.py"))
    let bundled = try Data(contentsOf: matinee.appending(path: "Matinee/Runtime.bundle/matinee_worker.py"))
    #expect(bundled == source, "run: cp Matinee/Worker/matinee_worker.py Matinee/Matinee/Runtime.bundle/")
}
