import XCTest
@testable import HermesBackup

final class UpdaterTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(Updater.isNewer("0.10.0", than: "0.9.2"))
        XCTAssertTrue(Updater.isNewer("1.0", than: "0.99.99"))
        XCTAssertTrue(Updater.isNewer("0.1.1", than: "0.1"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.2.0"))
    }

    func release(tag: String, assets: [String], draft: Bool = false, prerelease: Bool = false) -> Data {
        let a = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }
        return Data(#"""
        {"tag_name":"\#(tag)","body":"Notes","html_url":"https://github.com/x/y/releases/tag/\#(tag)",
         "draft":\#(draft),"prerelease":\#(prerelease),"assets":[\#(a.joined(separator: ","))]}
        """#.utf8)
    }

    func testParsesTagAndPicksDMG() throws {
        let r = try XCTUnwrap(Updater.parse(release(tag: "v0.2.0", assets: ["notes.txt", "Hermes-Backup-0.2.0.dmg"])))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.dmg.lastPathComponent, "Hermes-Backup-0.2.0.dmg")
        XCTAssertEqual(r.notes, "Notes")
    }

    func testIgnoresReleasesWithoutDMGOrNotFinal() throws {
        XCTAssertNil(try Updater.parse(release(tag: "v0.2.0", assets: ["source.zip"])))
        XCTAssertNil(try Updater.parse(release(tag: "v0.2.0", assets: ["a.dmg"], prerelease: true)))
        XCTAssertNil(try Updater.parse(release(tag: "v0.2.0", assets: ["a.dmg"], draft: true)))
    }
}
