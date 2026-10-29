import AppKit
import SwiftUI
import WidgetKit
import XCTest

/// FLAS-82: the appearance setting, its defaults and the one-time light themes migration.
final class AppearanceSettingTests: XCTestCase {
    private var directory: URL!
    private var storage: SettingsStorage!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = SettingsStorage(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: storage.fileURL)
    }

    func testNewSettingsAreLightAndOrange() {
        XCTAssertEqual(AppSettings().appearance, .light)
        XCTAssertEqual(AppSettings().accent, .orange)
        XCTAssertTrue(AppSettings().didMigrateLightTheme1, "new settings have nothing to migrate")
        XCTAssertEqual(storage.load().appearance, .light, "missing file loads defaults")
    }

    func testEveryAppearanceRoundTrips() throws {
        for appearance in AppearanceChoice.allCases {
            var settings = AppSettings()
            settings.appearance = appearance
            try storage.save(settings)
            XCTAssertEqual(storage.load().appearance, appearance)
        }
    }

    func testMissingOrUnknownAppearanceDecodesAsLight() throws {
        try write(#"{"appearance":"sepia","didMigrateLightTheme1":true}"#)
        XCTAssertEqual(storage.load().appearance, .light)
        try write(#"{"accent":"teal"}"#)
        XCTAssertEqual(storage.load().appearance, .light)
    }

    func testAFileFromBeforeLightThemesHasNotMigrated() throws {
        try write(#"{"accent":"indigo","showsNotch":true}"#)
        XCTAssertFalse(storage.load().didMigrateLightTheme1)
    }

    func testTheMigrationMovesIndigoToOrangeAndKeepsTheOthers() {
        for (before, after) in [(AccentChoice.indigo, AccentChoice.orange), (.blue, .blue), (.purple, .purple), (.teal, .teal)] {
            var old = AppSettings(accent: before)
            old.appearance = .dark
            old.didMigrateLightTheme1 = false
            let (migrated, didChange) = LightThemeMigration.apply(old)
            XCTAssertTrue(didChange)
            XCTAssertEqual(migrated.accent, after, "\(before)")
            XCTAssertEqual(migrated.appearance, .light, "everyone starts in Light")
            XCTAssertTrue(migrated.didMigrateLightTheme1)
        }
    }

    func testTheMigrationLeavesMigratedSettingsAlone() {
        var settings = AppSettings(accent: .indigo)
        settings.appearance = .dark
        let (same, didChange) = LightThemeMigration.apply(settings)
        XCTAssertFalse(didChange)
        XCTAssertEqual(same, settings)
    }
}

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private var directory: URL!
    private var storage: SettingsStorage!
    private var reloads = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        storage = SettingsStorage(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reloads = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(storage: storage, onSaved: { [unowned self] in reloads += 1 })
    }

    func testANewUserStartsInLightOrange() {
        let store = makeStore()
        XCTAssertEqual(store.appearance, .light)
        XCTAssertEqual(store.accent, .orange)
        XCTAssertEqual(reloads, 0, "nothing to migrate, nothing saved")
    }

    func testAnUpdateFromIndigoGivesLightAndOrange() throws {
        // What every earlier version saved: the whole struct, with the old default accent.
        try Data(#"{"accent":"indigo","dailyGoal":30,"showsNotch":false}"#.utf8).write(to: storage.fileURL)
        let store = makeStore()
        XCTAssertEqual(store.appearance, .light)
        XCTAssertEqual(store.accent, .orange)
        XCTAssertEqual(store.dailyGoal, 30, "other settings are untouched")
        XCTAssertFalse(store.showsNotch)
        XCTAssertEqual(reloads, 1, "the migrated settings are saved, and the widget told")
        XCTAssertTrue(storage.load().didMigrateLightTheme1)
        XCTAssertEqual(storage.load().accent, .orange)
    }

    func testAnUpdateFromTealKeepsTeal() throws {
        try Data(#"{"accent":"teal"}"#.utf8).write(to: storage.fileURL)
        let store = makeStore()
        XCTAssertEqual(store.appearance, .light)
        XCTAssertEqual(store.accent, .teal)
    }

    func testTheMigrationRunsOnceSoALaterChoiceSurvivesRelaunch() throws {
        try Data(#"{"accent":"indigo"}"#.utf8).write(to: storage.fileURL)
        let first = makeStore()
        first.appearance = .dark
        first.accent = .indigo

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.appearance, .dark)
        XCTAssertEqual(relaunched.accent, .indigo)
    }

    func testChangingTheAppearanceSavesItForTheWidgetAndReloadsIt() {
        let store = makeStore()
        store.appearance = .dark
        XCTAssertEqual(reloads, 1)
        store.appearance = .dark
        XCTAssertEqual(reloads, 1, "the same value is a no-op")
        // The widget extension reads the same file through its own storage.
        XCTAssertEqual(SettingsStorage(directory: directory).load().appearance, .dark)
        store.appearance = .system
        XCTAssertEqual(SettingsStorage(directory: directory).load().appearance, .system)
    }

    /// The toolbar button, its menu, View ▸ Appearance and the Settings tiles all bind to the one value.
    func testToolbarMenuAndSettingsShowTheSameChoice() {
        let store = makeStore()
        store.appearance = .dark // as the toolbar menu does
        XCTAssertEqual(AppearanceMenuItems.items(selected: store.appearance).filter(\.isChecked).map(\.choice), [.dark])
        store.appearance = .system // as a Settings tile does
        XCTAssertEqual(AppearanceMenuItems.items(selected: store.appearance).filter(\.isChecked).map(\.choice), [.system])
    }

    func testTheControllerSetsTheAppsAppearance() {
        XCTAssertEqual(AppearanceController.nsAppearance(for: .light)?.name, .aqua)
        XCTAssertEqual(AppearanceController.nsAppearance(for: .dark)?.name, .darkAqua)
        XCTAssertNil(AppearanceController.nsAppearance(for: .system), "Match system follows the Mac")
    }

    func testTheFrostedWindowUsesAMaterialForEachAppearance() {
        XCTAssertEqual(FrostedWindowBackground.material(for: .dark), .hudWindow)
        XCTAssertNotEqual(FrostedWindowBackground.material(for: .light), .hudWindow, "the HUD material is dark")
    }
}

final class AppearanceControlTests: XCTestCase {
    func testMatchSystemFollowsTheMacAndTheIconFollowsIt() {
        XCTAssertEqual(AppearanceChoice.system.resolved(system: .dark), .dark)
        XCTAssertEqual(AppearanceChoice.system.resolved(system: .light), .light)
        XCTAssertEqual(AppearanceChoice.light.resolved(system: .dark), .light)
        XCTAssertEqual(AppearanceChoice.dark.resolved(system: .light), .dark)
        XCTAssertEqual(AppearanceChoice.iconName(for: AppearanceChoice.system.resolved(system: .dark)), "moon.fill")
        XCTAssertEqual(AppearanceChoice.iconName(for: AppearanceChoice.system.resolved(system: .light)), "sun.max.fill")
    }

    func testTheButtonsAccessibilityValue() {
        XCTAssertEqual(AppearanceChoice.light.accessibilityValue(system: .dark), "Light")
        XCTAssertEqual(AppearanceChoice.dark.accessibilityValue(system: .light), "Dark")
        XCTAssertEqual(AppearanceChoice.system.accessibilityValue(system: .light), "Match system, now light")
        XCTAssertEqual(AppearanceChoice.system.accessibilityValue(system: .dark), "Match system, now dark")
    }

    func testTheMenuItemsAndTheirChecks() {
        let items = AppearanceMenuItems.items(selected: .dark)
        XCTAssertEqual(items.map(\.title), ["Light", "Dark", "Match system"])
        XCTAssertEqual(items.map(\.isChecked), [false, true, false])
    }

    func testTheButtonMovesIntoTheMoreMenuWhenNarrow() {
        XCTAssertEqual(DeckToolbar.moreMenuTitles(hasExport: true, appearanceInMenu: false), ["Export…"])
        XCTAssertEqual(DeckToolbar.moreMenuTitles(hasExport: true, appearanceInMenu: true), ["Export…", "Appearance"])
    }

    @MainActor
    func testTheToolbarWithTheButtonIsWiderAndTheMenuVersionIsNot() {
        var choice = AppearanceChoice.light
        let binding = Binding(get: { choice }, set: { choice = $0 })
        func width(_ toolbar: DeckToolbar) -> CGFloat {
            NSHostingView(rootView: toolbar.environment(\.colorScheme, .light)).fittingSize.width
        }
        let plain = width(DeckToolbar(onAddCard: {}, onExport: {}))
        let withButton = width(DeckToolbar(onAddCard: {}, onExport: {}, appearance: binding))
        let inMenu = width(DeckToolbar(onAddCard: {}, onExport: {}, appearance: binding, appearanceInMenu: true))
        XCTAssertEqual(withButton, plain + AppearanceButton.size + 8, accuracy: 1)
        XCTAssertEqual(inMenu, plain, accuracy: 1, "in the ⋯ menu it takes no room")
    }
}

/// FLAS-83: the widget follows the shared appearance.
@MainActor
final class WidgetAppearanceTests: XCTestCase {
    /// A square in the primary text color.
    private func probe(_ choice: AppearanceChoice, outside: ColorScheme) throws -> (r: Double, g: Double, b: Double) {
        let view = Rectangle().fill(Theme.TextColor.primary).frame(width: 10, height: 10)
            .modifier(WidgetAppearance(choice: choice))
            .environment(\.colorScheme, outside)
        let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    func testTheWidgetUsesTheChosenAppearance() throws {
        XCTAssertLessThan(try probe(.light, outside: .dark).r, 0.2, "Light on a dark desktop draws dark text")
        XCTAssertGreaterThan(try probe(.dark, outside: .light).r, 0.9, "Dark on a light desktop draws white text")
        XCTAssertGreaterThan(try probe(.system, outside: .dark).r, 0.9, "Match system leaves the system's choice")
        XCTAssertLessThan(try probe(.system, outside: .light).r, 0.2)
    }

    func testTheEntryCarriesTheAppearance() {
        let entry = FishBrainEntry.make(decks: [], playback: [:], accent: .teal, appearance: .dark, at: Date())
        XCTAssertEqual(entry.appearance, .dark)
        XCTAssertEqual(FishBrainEntry.make(decks: [], playback: [:], accent: .teal, at: Date()).appearance, .light)
    }

    func testEveryFamilyRendersInEveryPalette() throws {
        let sizes: [(WidgetFamily, CGSize)] = [
            (.systemSmall, CGSize(width: 158, height: 158)),
            (.systemMedium, CGSize(width: 338, height: 158)),
            (.systemLarge, CGSize(width: 338, height: 354)),
        ]
        for appearance in [AppearanceChoice.light, .dark] {
            for accent in AccentChoice.allCases {
                let entries = [
                    FishBrainEntry.sample(accent: accent, appearance: appearance),
                    FishBrainEntry.sample(flipped: true, accent: accent, appearance: appearance),
                    FishBrainEntry.make(decks: [], playback: [:], accent: accent, appearance: appearance, at: Date()),
                ]
                for (family, size) in sizes {
                    for entry in entries {
                        let view = FishBrainWidgetContent(entry: entry, family: family).frame(width: size.width, height: size.height)
                        let image = try XCTUnwrap(ImageRenderer(content: view).cgImage, "\(appearance) \(accent) \(family)")
                        XCTAssertEqual(image.width, Int(size.width))
                    }
                }
            }
        }
    }
}
