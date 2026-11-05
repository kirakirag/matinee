import Testing
import MatineeKit

@Test func routesAreHashable() {
    let uc = "UCXuqSBlHAE6Xw-yeJA0Tunw"
    #expect(Route.channel(.id(uc), name: "A") == .channel(.id(uc), name: "A"))
    #expect(Route.channel(.id(uc), name: "A") != .channel(.id(uc), name: "B"))
    #expect(Route.channel(.id(uc), name: nil) != .channel(.handle("@a"), name: nil))
    #expect(Route.playlist(id: "PL1", title: "T") == .playlist(id: "PL1", title: "T"))
    #expect(Route.playlist(id: "PL1", title: "T") != .playlist(id: "PL2", title: "T"))
    #expect(Route.playlist(id: "PL1", title: nil) != .channel(.id(uc), name: nil))
    #expect(Set([Route.playlist(id: "PL1", title: nil), .playlist(id: "PL1", title: nil)]).count == 1)
}
