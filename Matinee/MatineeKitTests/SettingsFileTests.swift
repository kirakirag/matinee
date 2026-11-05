import Foundation
import Testing
import MatineeKit

private func freshDefaults() -> UserDefaults {
    let name = "SettingsFileTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func jsonListsEverySettingWithItsDefault() throws {
    let o = try object(SettingsFile.json(from: freshDefaults()))
    #expect(o["defaultQuality"] as? Int == 0)
    #expect(o["openglPlayback"] as? Bool == false)
    #expect(o["dearrowTitles"] as? Bool == true)
    #expect(o["dearrowThumbnails"] as? Bool == true)
    #expect(o["showComments"] as? Bool == false)
    #expect(o["recommendations"] as? Bool == true)
    #expect(o["localModels"] as? Bool == true)
    #expect(o["braveProfile"] as? String == "")
    let sponsor = try #require(o["sponsorblock"] as? [String: Bool])
    #expect(sponsor == Dictionary(uniqueKeysWithValues: SponsorBlock.categories.map { ($0.id, $0.defaultOn) }))
    #expect(o.count == 9)
}

@Test func jsonReflectsStoredValues() throws {
    let d = freshDefaults()
    d.set(1080, forKey: "defaultQuality")
    d.set(true, forKey: "showComments")
    d.set("Profile 2", forKey: "braveProfile")
    d.set(true, forKey: "sponsorblock.intro")
    let o = try object(SettingsFile.json(from: d))
    #expect(o["defaultQuality"] as? Int == 1080)
    #expect(o["showComments"] as? Bool == true)
    #expect(o["braveProfile"] as? String == "Profile 2")
    #expect((o["sponsorblock"] as? [String: Bool])?["intro"] == true)
}

@Test func applySetsOnlyTheKeysGiven() throws {
    let d = freshDefaults()
    d.set(720, forKey: "defaultQuality")
    let problems = try SettingsFile.apply(Data(#"{"showComments": true, "sponsorblock": {"intro": true}}"#.utf8), to: d)
    #expect(problems.isEmpty)
    #expect(d.bool(forKey: "showComments"))
    #expect(d.bool(forKey: "sponsorblock.intro"))
    #expect(d.integer(forKey: "defaultQuality") == 720)
    #expect(d.object(forKey: "recommendations") == nil)
}

@Test func applyRoundTripsJSON() throws {
    let a = freshDefaults()
    a.set(480, forKey: "defaultQuality")
    a.set(false, forKey: "recommendations")
    a.set(false, forKey: "sponsorblock.sponsor")
    let b = freshDefaults()
    #expect(try SettingsFile.apply(SettingsFile.json(from: a), to: b).isEmpty)
    #expect(SettingsFile.json(from: b) == SettingsFile.json(from: a))
}

@Test func applyReportsBadValuesAndUnknownKeysAndKeepsTheRest() throws {
    let d = freshDefaults()
    let json = #"{"defaultQuality": 999, "showComments": "yes", "colour": 1, "sponsorblock": {"nope": true, "intro": 1}, "dearrowTitles": false}"#
    let problems = try SettingsFile.apply(Data(json.utf8), to: d)
    #expect(Set(problems) == ["defaultQuality", "showComments", "colour", "sponsorblock.nope", "sponsorblock.intro"])
    #expect(d.object(forKey: "defaultQuality") == nil)
    #expect(d.object(forKey: "showComments") == nil)
    #expect(d.object(forKey: "sponsorblock.intro") == nil)
    #expect(d.object(forKey: "dearrowTitles") as? Bool == false)
}

@Test func applyRejectsInvalidJSONAndChangesNothing() {
    let d = freshDefaults()
    #expect(throws: (any Error).self) { try SettingsFile.apply(Data(#"{"showComments": true"#.utf8), to: d) }
    #expect(throws: (any Error).self) { try SettingsFile.apply(Data("[1]".utf8), to: d) }
    #expect(d.object(forKey: "showComments") == nil)
}
