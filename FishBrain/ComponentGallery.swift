import SwiftUI

/// Every shared component on one screen, in light and dark side by side, with an accent picker to
/// check that changing the accent recolors all of them. Preview and test use only.
struct ComponentGallery: View {
    @State var accent: AccentChoice = .default
    /// The appearances shown, side by side.
    var schemes: [ColorScheme] = [.light, .dark]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Accent", selection: $accent) {
                ForEach(AccentChoice.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 400)
            HStack(alignment: .top, spacing: 0) {
                ForEach(schemes, id: \.self) { scheme in
                    sheet
                        .padding(28)
                        .background(Theme.Surface.previewBackdrop)
                        .environment(\.colorScheme, scheme)
                }
            }
        }
        .environment(\.accentChoice, accent)
        .padding(16)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 20) {

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(name: "Everyday Spanish", count: 48, color: .accent, isSelected: true)
                    SidebarRow(name: "Biology 101", count: 32, color: .green)
                    SidebarRow(name: "Swift Interview", count: 20, color: .purple)
                    SidebarRow(name: "World Capitals", count: 60, color: .orange)
                }
                .frame(width: 240)

                GlassPanel {
                    VStack(spacing: 0) {
                        Text("la mariposa").padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        HairlineDivider()
                        Text("el desayuno").padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.TextColor.primary)
                }
                .frame(width: 240)
            }

            HStack(spacing: 8) {
                Button("Import…") {}.buttonStyle(.capsuleSecondary)
                Button("Paste Cards") {}.buttonStyle(.capsuleSecondary)
                Button("Add Card") {}.buttonStyle(.capsulePrimary)
                ForEach(DeckColor.allCases, id: \.self) { DeckIcon(color: $0, size: 28) }
            }

            VStack(alignment: .leading, spacing: 10) {
                CountdownProgressBar(progress: 0.62).frame(width: 320)
                CountdownProgressBar(progress: 0.3, height: 3).frame(width: 320)
            }

            HStack(spacing: 16) {
                CardFace(text: "la sobremesa", size: .small)
                    .frame(width: 170, height: 170)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.widget, style: .continuous).fill(Theme.Surface.widget))
                CardFace(text: "lingering at the table after a meal", isBack: true, size: .small)
                    .frame(width: 170, height: 170)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.widget, style: .continuous).fill(accent.flippedSurface))
            }
        }
    }
}

#Preview("All components") {
    ComponentGallery()
}
