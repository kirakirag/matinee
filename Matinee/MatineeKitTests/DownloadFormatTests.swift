import Foundation
import MatineeKit
import Testing

@Test func detailReadsPercentSizesSpeedAndTimeLeft() {
    let p = DownloadProgress(downloaded: 120_000_000, total: 260_000_000, fraction: 0.4615, speed: 4_000_000, eta: 33.2)
    #expect(DownloadFormat.detail(p) == "46% · 120 MB of 260 MB · 4 MB/s · 34 sec left")
}

@Test func detailWithoutATotalShowsBytesAndSpeedOnly() {
    #expect(DownloadFormat.detail(DownloadProgress(downloaded: 5_000_000, total: nil, speed: 1_000_000))
            == "5 MB · 1 MB/s")
    #expect(DownloadFormat.detail(DownloadProgress(downloaded: 5_000_000, total: nil)) == "5 MB")
}

@Test func detailWhileMergingSaysFinishing() {
    #expect(DownloadFormat.detail(DownloadProgress(downloaded: 1, total: 1, fraction: 1, stage: .finishing)) == "Finishing…")
}

@Test func timeLeftUsesTwoUnitsAtMost() {
    #expect(DownloadFormat.timeLeft(0.2) == "1 sec left")
    #expect(DownloadFormat.timeLeft(125) == "2 min, 5 sec left")
    #expect(DownloadFormat.timeLeft(3 * 3600 + 61) == "3 hr, 1 min left")
}
