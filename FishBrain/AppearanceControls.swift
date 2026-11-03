import AppKit
import Combine
import SwiftUI

/// Applies the appearance setting to the whole app (every window, sheet, menu and alert) by setting
/// `NSApp.appearance`, at launch and whenever the setting changes. The notch opts out: it is always dark.
@MainActor
final class AppearanceController {
    static let shared = AppearanceController()

    private var subscription: AnyCancellable?

    func start(settings: SettingsStore) {
        subscription = settings.$appearance.sink { choice in
            NSApplication.shared.appearance = Self.nsAppearance(for: choice)
        }
    }

    /// nil follows the Mac.
    static func nsAppearance(for choice: AppearanceChoice) -> NSAppearance? {
        switch choice {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

/// The three choices as menu items, each checked when it is the current one. Used by View ▸ Appearance
/// and by the ⋯ menu when the toolbar is too narrow for the button.
struct AppearanceMenuItems: View {
    @Binding var selection: AppearanceChoice

    /// Titles in menu order, and which one is checked.
    static func items(selected: AppearanceChoice) -> [(choice: AppearanceChoice, title: String, isChecked: Bool)] {
        AppearanceChoice.allCases.map { ($0, $0.displayName, $0 == selected) }
    }

    var body: some View {
        ForEach(Self.items(selected: selection), id: \.choice) { item in
            Toggle(item.title, isOn: Binding(
                get: { item.isChecked },
                set: { if $0 { selection = item.choice } }
            ))
        }
    }
}

/// The round sun or moon button in the deck and subject toolbars. It shows the appearance on screen
/// now; a click opens a small menu of Light, Dark and Match system.
struct AppearanceButton: View {
    @Binding var selection: AppearanceChoice

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accentChoice) private var accent
    @State private var isOpen = false

    static let size: CGFloat = 34

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: AppearanceChoice.iconName(for: scheme))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOpen ? Theme.TextColor.onAccent : Theme.TextColor.primary)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(isOpen ? accent.fill : Theme.Surface.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Appearance")
        .accessibilityLabel("Appearance")
        .accessibilityValue(selection.accessibilityValue(system: scheme))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            AppearancePopoverMenu(selection: selection) { choice in
                selection = choice
                isOpen = false
            }
        }
    }
}

/// The button's menu: one row per choice, a check on the current one. Esc or a click outside closes it.
private struct AppearancePopoverMenu: View {
    var selection: AppearanceChoice
    var onChoose: (AppearanceChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(AppearanceMenuItems.items(selected: selection), id: \.choice) { item in
                Button { onChoose(item.choice) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .opacity(item.isChecked ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(item.title)
                            .font(Theme.Typography.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.TextColor.primary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 150, minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item.isChecked ? .isSelected : [])
            }
        }
        .padding(6)
    }
}

/// Settings > General: Light, Dark and Match system as tiles, each with a small window drawn in that
/// appearance and the current accent. The chosen tile has an accent border.
struct AppearanceTiles: View {
    @Binding var selection: AppearanceChoice

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppearanceChoice.allCases, id: \.self) { choice in
                Button { selection = choice } label: {
                    VStack(spacing: 6) {
                        AppearanceThumbnail(choice: choice)
                            .frame(width: 112, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(choice == selection ? accent.fill : Theme.Surface.hairline, lineWidth: choice == selection ? 2 : 1)
                            }
                        Text(choice.displayName)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(choice == selection ? Theme.TextColor.primary : Theme.TextColor.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.displayName)
                .accessibilityAddTraits(choice == selection ? .isSelected : [])
            }
        }
    }
}

/// A tiny window: sidebar with a selected row, and a card. Match system is half light, half dark.
private struct AppearanceThumbnail: View {
    var choice: AppearanceChoice

    var body: some View {
        switch choice {
        case .light: MiniWindow().environment(\.colorScheme, .light)
        case .dark: MiniWindow().environment(\.colorScheme, .dark)
        case .system:
            HStack(spacing: 0) {
                MiniWindow().environment(\.colorScheme, .light)
                    .frame(width: 56, alignment: .leading).clipped()
                MiniWindow().environment(\.colorScheme, .dark)
                    .frame(width: 56, alignment: .trailing).clipped()
            }
        }
    }

    private struct MiniWindow: View {
        @Environment(\.accentChoice) private var accent

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(accent.fill).frame(height: 8)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.TextColor.secondary.with(opacity: 0.5)).frame(height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.TextColor.secondary.with(opacity: 0.5)).frame(height: 5)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 38)
                .background(accent.sidebar.with(opacity: 1))
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.TextColor.primary).frame(width: 34, height: 6)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.Surface.group.with(opacity: 1))
                        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 1) }
                    Capsule().fill(accent.fill).frame(width: 30, height: 7)
                }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.window.with(opacity: 1))
            }
            .frame(width: 112, height: 72)
        }
    }
}

#if DEBUG
#Preview("Appearance controls") {
    struct Demo: View {
        @State var selection = AppearanceChoice.light
        var body: some View {
            VStack(spacing: 20) {
                AppearanceTiles(selection: $selection)
                AppearanceButton(selection: $selection)
            }
            .padding(24)
            .background(Theme.Surface.previewBackdrop)
        }
    }
    return Demo()
}
#endif
