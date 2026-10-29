import SwiftUI

/// One selectable accent color. Selected is marked with a ring, not just color.
struct AccentSwatch: View {
    var choice: AccentChoice
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(choice.fill)
                    .frame(width: 28, height: 28)
                    .padding(3)
                    .overlay {
                        if isSelected {
                            Circle().strokeBorder(Theme.TextColor.primary, lineWidth: 2)
                        }
                    }
                Text(choice.displayName)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(isSelected ? Theme.TextColor.primary : Theme.TextColor.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A switch with a one-line explanation under its title.
struct SettingToggleRow: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
                Text(detail)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.Surface.switchOn.color)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
}

enum DailyGoal {
    /// The offered goals, plus the saved one if it isn't among them (a settings file edited by hand).
    static func choices(including current: Int) -> [Int] {
        (AppSettings.dailyGoalChoices + [current]).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }
}

/// Which tab Settings shows, so other screens can open it on the right one ("Set up an AI provider").
@MainActor
final class SettingsNavigator: ObservableObject {
    enum Tab: Hashable { case general, notch, ai }

    static let shared = SettingsNavigator()

    @Published var tab: Tab = .general
}

/// Settings: General, Notch and AI.
struct SettingsView: View {
    static let width: CGFloat = 520
    static let height: CGFloat = 600

    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        TabView(selection: $navigator.tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsNavigator.Tab.general)
            NotchSettingsTab()
                .tabItem { Label("Notch", systemImage: "rectangle.topthird.inset.filled") }
                .tag(SettingsNavigator.Tab.notch)
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsNavigator.Tab.ai)
        }
        .frame(width: Self.width, height: Self.height)
        .background {
            ZStack {
                Rectangle().fill(Theme.Blur.window)
                Rectangle().fill(Theme.Surface.window)
            }
        }
    }
}

/// A tab's page: scrolls when it is taller than the window.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsHeading: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.body.weight(.semibold))
            .foregroundStyle(Theme.TextColor.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage {
            SettingsHeading(text: "Appearance")
            AppearanceTiles(selection: $settings.appearance)
            Text("Also in the toolbar and in View > Appearance.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)

            HairlineDivider().padding(.vertical, 6)

            SettingsHeading(text: "Accent color")
            HStack(spacing: 18) {
                ForEach(AccentChoice.allCases, id: \.self) { choice in
                    AccentSwatch(choice: choice, isSelected: settings.accent == choice) {
                        settings.accent = choice
                    }
                }
            }
            Text("Used by the app, the widgets and the notch, in light and dark.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)

            HairlineDivider().padding(.vertical, 6)

            SettingsHeading(text: "Study")
            SettingToggleRow(
                title: "Grade with the keyboard",
                detail: "Press 1 (Again) to 4 (Easy) in the open notch. While a card is turned over the notch takes the keyboard, so typing in another app waits until you grade the card or move away.",
                isOn: $settings.keyboardGrading
            )
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily goal")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.TextColor.primary)
                    Text("Cards to study each day to keep your streak. A card counts when you flip it to its answer, once a day.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Picker("Daily goal", selection: $settings.dailyGoal) {
                    ForEach(DailyGoal.choices(including: settings.dailyGoal), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Daily goal, cards per day")
            }
        }
    }
}

/// "Flip every", under the style picker while Card is picked.
struct NotchFlipIntervalRow: View {
    @Binding var selection: NotchFlipInterval

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Flip every")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
                Text("How long the card shows each side before it turns over. Off shows the front only. It only changes what the notch shows: it doesn't count as studying.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("Flip every", selection: $selection) {
                ForEach(NotchFlipInterval.choices, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Flip every")
        }
    }
}

private struct NotchSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var displays = NotchDisplayManager.shared

    var body: some View {
        SettingsPage {
            SettingsHeading(text: "Notch")
            Text("Macs without a notch, and any display you switch on below, get a notch FishBrain draws itself.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingToggleRow(
                title: "Show on external displays",
                detail: "Also show it on every other monitor, not only the Mac's own display.",
                isOn: $settings.showsOnExternalDisplays
            )
            SettingToggleRow(
                title: "Hide when an app is full screen",
                detail: "Hides it on a display while a full-screen app is in front there, or while its menu bar is hidden.",
                isOn: $settings.hidesInFullScreen
            )
            SettingToggleRow(
                title: "Only on the display with the active menu bar",
                detail: "Shows it on the display you are working on and moves with you. Off shows it on every enabled display.",
                isOn: $settings.onlyOnActiveDisplay
            )
            PillStylePicker(selection: $settings.pillStyle, hasDrawnNotch: displays.hasDrawnNotch, flipInterval: settings.notchFlipInterval)
            if settings.pillStyle == .card {
                NotchFlipIntervalRow(selection: $settings.notchFlipInterval)
            }
            Text("\"Show in notch\" in the sidebar turns all of it on or off.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)

            HairlineDivider().padding(.vertical, 6)

            SettingsHeading(text: "Cards from what you copy")
            SettingToggleRow(
                title: "Offer to make a card when I copy text",
                detail: "After you copy a word or short phrase in another app, the notch offers to turn it into a card. Control-Option-C opens a new card from whatever you last copied. FishBrain only looks at what you copy while this is on, and never at anything a password manager marks as secret.",
                isOn: $settings.offersCardFromCopy
            )
            Text("macOS may ask to let FishBrain read what you copy. To show the copied text on the offer without asking, set FishBrain to Allow in System Settings > Privacy & Security > Paste from Other Apps.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Settings") {
    let settings = SettingsStore(storage: SettingsStorage(directory: FileManager.default.temporaryDirectory))
    SettingsView()
        .environmentObject(settings)
        .environmentObject(AIAccountStore(
            secrets: InMemorySecretStore(), cacheStorage: AIModelCacheStorage(directory: FileManager.default.temporaryDirectory), settings: settings
        ))
}
