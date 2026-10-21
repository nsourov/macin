import XCTest
@testable import FootprintCore

final class UpdateTests: XCTestCase {
    func testVersionOrder() {
        XCTAssertTrue(VersionOrder.isNewer("v0.1.3", than: "0.1.2"))
        XCTAssertTrue(VersionOrder.isNewer("0.2", than: "0.1.9"))
        XCTAssertTrue(VersionOrder.isNewer("1.0.0", than: "0.10.0"))
        XCTAssertFalse(VersionOrder.isNewer("v0.1.2", than: "0.1.2"))
        XCTAssertFalse(VersionOrder.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(VersionOrder.isNewer("0.1.1", than: "0.1.2"))
    }

    func testParsesGitHubRelease() throws {
        let json = """
        {"tag_name": "v0.1.3", "body": "Fixes", "draft": false, "prerelease": false,
         "assets": [{"name": "Other.zip", "browser_download_url": "https://example.com/Other.zip"},
                    {"name": "Macin.dmg", "browser_download_url": "https://example.com/Macin.dmg"}]}
        """
        let release = try XCTUnwrap(AppRelease.parseGitHub(Data(json.utf8), assetName: "Macin.dmg"))
        XCTAssertEqual(release.version, "0.1.3")
        XCTAssertEqual(release.notes, "Fixes")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://example.com/Macin.dmg")
    }

    func testSkipsReleaseWithoutSafeAsset() throws {
        let missing = #"{"tag_name": "v0.2.0", "assets": []}"#
        XCTAssertNil(try AppRelease.parseGitHub(Data(missing.utf8), assetName: "Macin.dmg"))
        let insecure = #"{"tag_name": "v0.2.0", "assets": [{"name": "Macin.dmg", "browser_download_url": "http://example.com/Macin.dmg"}]}"#
        XCTAssertNil(try AppRelease.parseGitHub(Data(insecure.utf8), assetName: "Macin.dmg"))
        let pre = #"{"tag_name": "v0.2.0", "prerelease": true, "assets": [{"name": "Macin.dmg", "browser_download_url": "https://example.com/Macin.dmg"}]}"#
        XCTAssertNil(try AppRelease.parseGitHub(Data(pre.utf8), assetName: "Macin.dmg"))
    }
}
