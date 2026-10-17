import XCTest

final class ReleaseTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheChangelogHasNotesForTheCurrentVersion() throws {
        let yml = try text("project.yml")
        let line = try XCTUnwrap(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION") })
        let version = line.split(separator: "\"").dropFirst().first.map(String.init)
        let marketing = try XCTUnwrap(version)
        XCTAssertTrue(try text("CHANGELOG.md").contains("## \(marketing)\n"), "CHANGELOG.md needs a '## \(marketing)' section")
    }

    func testTheReleaseScriptExistsAndIsExecutable() throws {
        let url = root.appendingPathComponent("Scripts/release.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        let script = try text("Scripts/release.sh")
        XCTAssertTrue(script.contains("notarytool submit"))
        XCTAssertTrue(script.contains("stapler staple"))
        XCTAssertFalse(script.contains("password"), "no credentials in the script")
    }

    func testBothTargetsKeepTheHardenedRuntime() throws {
        let yml = try text("project.yml")
        XCTAssertEqual(yml.components(separatedBy: "ENABLE_HARDENED_RUNTIME: true").count - 1, 2)
    }

    func testTheAppSharesItsVersionWithTheWidget() throws {
        let yml = try text("project.yml")
        XCTAssertEqual(yml.components(separatedBy: "CFBundleShortVersionString: $(MARKETING_VERSION)").count - 1, 2)
        XCTAssertEqual(yml.components(separatedBy: "CFBundleVersion: $(CURRENT_PROJECT_VERSION)").count - 1, 2)
    }
}
