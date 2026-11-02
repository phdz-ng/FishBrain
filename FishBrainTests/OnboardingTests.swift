import AppKit
import XCTest

final class GettingStartedContentTests: XCTestCase {
    func testTheDeckExplainsEveryTopicTheTicketNames() {
        let text = GettingStarted.cards.map { "\($0.front) \($0.back)" }.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("flip"), "flipping")
        XCTAssertTrue(text.contains("5 minutes"), "the rotation")
        XCTAssertTrue(text.contains("choose edit widget") || text.contains("pick a deck"), "choosing a widget deck")
        XCTAssertTrue(text.contains("paste cards") && text.contains("import csv"), "bulk import")
        XCTAssertTrue(text.contains("edit widgets"), "adding the widget")
    }

    func testNoCardIsBlank() {
        for card in GettingStarted.cards {
            XCTAssertFalse(card.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    func testEachCallMakesAFreshDeckWithTheSameCards() {
        let first = GettingStarted.deck()
        let second = GettingStarted.deck()
        XCTAssertEqual(first.name, "Getting Started")
        XCTAssertEqual(first.cards.map(\.front), GettingStarted.cards.map(\.front))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(Set(first.cards.map(\.id)).isDisjoint(with: second.cards.map(\.id)))
        XCTAssertEqual(Set(first.cards.map(\.id)).count, first.cards.count)
    }

    func testTheWelcomeStepsExplainTheWidget() {
        let steps = Welcome.steps(hasGettingStartedDeck: true)
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].detail.contains("Right-click"))
        XCTAssertTrue(steps[0].detail.contains("Edit Widgets"))
        XCTAssertTrue(steps[1].title.contains("notch"))
    }

    func testTheDeckStepIsLeftOutWhenThereIsNoDeck() {
        let steps = Welcome.steps(hasGettingStartedDeck: false)
        XCTAssertEqual(steps.count, 2)
        XCTAssertFalse(steps.contains { $0.title.contains("Getting Started") })
    }
}

@MainActor
final class FirstLaunchTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStores() -> (DeckStore, SettingsStore) {
        let decks = DeckStore(storage: DeckStorage(directory: directory), debounce: .milliseconds(1), onSaved: {})
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: {})
        return (decks, settings)
    }

    func testAnEmptyLibraryGetsTheGettingStartedDeck() {
        let (decks, settings) = makeStores()
        FirstLaunch.run(decks: decks, settings: settings)
        XCTAssertEqual(decks.decks.map(\.name), ["Getting Started"])
        XCTAssertEqual(decks.decks.first?.cards.count, GettingStarted.cards.count)
        XCTAssertTrue(settings.gettingStartedHandled)
    }

    func testAnExistingLibraryIsLeftAlone() {
        let (decks, settings) = makeStores()
        decks.addDeck(name: "Spanish")
        FirstLaunch.run(decks: decks, settings: settings)
        XCTAssertEqual(decks.decks.map(\.name), ["Spanish"])
        XCTAssertTrue(settings.gettingStartedHandled, "an updating user is not offered it later either")
    }

    func testItOnlyHappensOnce() {
        let (decks, settings) = makeStores()
        FirstLaunch.run(decks: decks, settings: settings)
        FirstLaunch.run(decks: decks, settings: settings)
        XCTAssertEqual(decks.decks.count, 1)
    }

    func testADeletedDeckStaysDeletedAcrossLaunches() async {
        let (decks, settings) = makeStores()
        FirstLaunch.run(decks: decks, settings: settings)
        _ = decks.deleteDeck(decks.decks[0].id)
        await decks.pendingSave?.value

        let (reloadedDecks, reloadedSettings) = makeStores()
        XCTAssertTrue(reloadedSettings.gettingStartedHandled, "the flag was saved")
        FirstLaunch.run(decks: reloadedDecks, settings: reloadedSettings)
        XCTAssertTrue(reloadedDecks.decks.isEmpty)
    }

    func testTheWelcomeFlagIsSavedAndDoesNotReloadWidgets() {
        var reloads = 0
        let settings = SettingsStore(storage: SettingsStorage(directory: directory), onSaved: { reloads += 1 })
        XCTAssertFalse(settings.hasSeenWelcome)
        settings.hasSeenWelcome = true
        XCTAssertEqual(reloads, 0)
        XCTAssertTrue(SettingsStorage(directory: directory).load().hasSeenWelcome)
    }
}

final class OnboardingSettingsStorageTests: XCTestCase {
    func testAnOlderSettingsFileCountsAsNotYetOnboarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SettingsStorage(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"accent":"teal","showsNotch":false}"#.utf8).write(to: storage.fileURL)
        let loaded = storage.load()
        XCTAssertEqual(loaded.accent, .teal)
        XCTAssertFalse(loaded.showsNotch)
        XCTAssertFalse(loaded.gettingStartedHandled)
        XCTAssertFalse(loaded.hasSeenWelcome)
    }
}

final class AppIconTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var iconSet: URL {
        projectRoot.appendingPathComponent("FishBrain/Assets.xcassets/AppIcon.appiconset")
    }

    private struct Contents: Decodable {
        struct Image: Decodable {
            var filename: String?
            var size: String
            var scale: String
            var idiom: String
        }
        var images: [Image]
    }

    private func contents() throws -> Contents {
        try JSONDecoder().decode(Contents.self, from: Data(contentsOf: iconSet.appendingPathComponent("Contents.json")))
    }

    func testEveryMacIconSizeIsListed() throws {
        let listed = Set(try contents().images.map { "\($0.size)@\($0.scale)" })
        let expected: Set<String> = [
            "16x16@1x", "16x16@2x", "32x32@1x", "32x32@2x", "128x128@1x", "128x128@2x",
            "256x256@1x", "256x256@2x", "512x512@1x", "512x512@2x",
        ]
        XCTAssertEqual(listed, expected)
        XCTAssertTrue(try contents().images.allSatisfy { $0.idiom == "mac" })
    }

    func testEveryImageExistsAtItsPixelSizeAndIsNotBlank() throws {
        for image in try contents().images {
            let filename = try XCTUnwrap(image.filename, "\(image.size) has no file")
            let data = try Data(contentsOf: iconSet.appendingPathComponent(filename))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data), filename)
            let points = Int(try XCTUnwrap(Double(image.size.split(separator: "x")[0])))
            let scale = Int(try XCTUnwrap(Double(image.scale.dropLast())))
            XCTAssertEqual(rep.pixelsWide, points * scale, filename)
            XCTAssertEqual(rep.pixelsHigh, points * scale, filename)

            // The tile is centered and opaque; the corners (outside the rounded tile) are clear.
            let middle = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            XCTAssertGreaterThan(middle.alphaComponent, 0.9, "\(filename) center")
            let corner = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            XCTAssertLessThan(corner.alphaComponent, 0.1, "\(filename) corner")
        }
    }

    func testTheTileAndTheFishSitOnTheSplitWithSwappedColors() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: iconSet.appendingPathComponent("icon_512x512@2x.png"))))
        XCTAssertEqual(rep.pixelsWide, 1024)
        func rgb(_ x: Int, _ y: Int) throws -> [Int] {
            // colorAt hands back the stored values as they are, so there is no color conversion to account for.
            let c = try XCTUnwrap(rep.colorAt(x: x, y: y))
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        let pale = [0xFF, 0xA3, 0x6B], deep = [0xC2, 0x41, 0x0C]
        // Above the fish the tile is pale to the left of the center line and deep from it.
        XCTAssertEqual(try rgb(511, 150), pale)
        XCTAssertEqual(try rgb(512, 150), deep)
        // Level with the middle of the fish, away from it: the same split.
        XCTAssertEqual(try rgb(312, 512), pale)
        XCTAssertEqual(try rgb(712, 512), deep)
        // On the fish the halves are swapped: deep on the pale side, pale on the deep side.
        XCTAssertEqual(try rgb(511, 600), deep)
        XCTAssertEqual(try rgb(513, 600), pale)
    }

    func testTheIconComposerIconHasEveryLayerAndTheStyles() throws {
        let icon = projectRoot.appendingPathComponent("FishBrain/AppIcon.icon")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: icon.appendingPathComponent("icon.json"))) as? [String: Any])
        let groups = try XCTUnwrap(json["groups"] as? [[String: Any]])
        let layers = try XCTUnwrap(groups.first?["layers"] as? [[String: Any]])
        let names = layers.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["tile-left", "tile-left-dark", "tile-right", "fish-left", "fish-right", "eye"])
        for layer in layers {
            let image = try XCTUnwrap(layer["image-name"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: icon.appendingPathComponent("Assets/\(image)").path), image)
        }
        func layer(_ name: String) throws -> [String: Any] { try XCTUnwrap(layers.first { $0["name"] as? String == name }) }
        func appearances(_ layer: [String: Any], _ key: String) -> Set<String> {
            Set((layer[key] as? [[String: Any]] ?? []).compactMap { $0["appearance"] as? String })
        }
        // Dark swaps the pale left half of the tile for the dark one; Tinted (and Clear) drop the tile and the eye.
        XCTAssertEqual(appearances(try layer("tile-left"), "hidden-specializations"), ["dark", "tinted"])
        XCTAssertEqual(appearances(try layer("tile-left-dark"), "hidden-specializations"), ["dark"])
        XCTAssertEqual(appearances(try layer("tile-right"), "hidden-specializations"), ["tinted"])
        XCTAssertEqual(appearances(try layer("eye"), "hidden-specializations"), ["tinted"])
        // The two fish halves differ in strength there, not only in color.
        let tinted = try XCTUnwrap((try layer("fish-left")["opacity-specializations"] as? [[String: Any]])?.first { $0["appearance"] as? String == "tinted" })
        XCTAssertEqual(try XCTUnwrap(tinted["value"] as? Double), 0.55, accuracy: 0.001)

        let dark = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: icon.appendingPathComponent("Assets/tile-left-dark.png"))))
        let pixel = try XCTUnwrap(dark.colorAt(x: 100, y: 100))
        XCTAssertEqual([pixel.redComponent, pixel.greenComponent, pixel.blueComponent].map { Int(($0 * 255).rounded()) }, [0x3D, 0x24, 0x18])
    }

    func testTheAppTargetUsesTheIcon() throws {
        let yml = try String(contentsOf: projectRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"))
    }
}
