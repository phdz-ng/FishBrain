import AppKit
import SwiftUI

/// Step 1 of a CSV import: a card with Front and Back areas, the file's columns as chips to put on it, and
/// the options that decide what the rows are (skip the first row, the deck's name, deck and subject columns).
struct CSVBuildCardStep: View {
    @Binding var builder: CSVCardBuilder
    /// Cards the import would make, for "All 212 cards go to a new deck…".
    var cardCount: Int
    /// The deck the cards go to when they are added to one that exists ("Import CSV" on a deck).
    var existingDeckName: String?
    /// Change… next to the existing deck: step 2's "Where it goes".
    var onChangeDestination: () -> Void
    /// Why Next was refused, shown under the options.
    var problem: String?

    @Environment(\.accentChoice) private var accent
    @FocusState private var focus: Focus?

    enum Focus: Hashable {
        case area(CSVCardBuilder.Side)
        case cardChip(Int)
        case column(Int)
    }

    /// What a dragged chip carries: its column.
    private static let dragPrefix = "fishbrain-csv-column:"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Build your card")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("Click a side, then click the columns to put on it. Click a column on the card to take it off.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card
            columns
            options
        }
        // Keyboard focus starts on the side being added to, so it lines up with the outline.
        .defaultFocus($focus, .area(builder.activeSide))
        .onAppear { DispatchQueue.main.async { focus = .area(builder.activeSide) } }
    }

    // MARK: The card

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            area(.front)
            area(.back)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.Surface.group))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5)
        }
    }

    private func area(_ side: CSVCardBuilder.Side) -> some View {
        let isActive = builder.activeSide == side
        let list = builder.columns(on: side)
        return VStack(alignment: .leading, spacing: 10) {
            Text(isActive ? "\(side.title) · adding here" : side.title)
                .font(Theme.Typography.micro.weight(.semibold))
                .foregroundStyle(isActive ? accent.light : Theme.TextColor.secondary)
                .accessibilityHidden(true)
            if list.isEmpty {
                Text(isActive ? "Click a column below to add it." : "No column yet.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .accessibilityHidden(true)
            } else {
                WrapLayout(spacing: 10) {
                    ForEach(list, id: \.self) { column in cardChip(column, on: side) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.TextColor.primary.with(opacity: isActive ? 0.06 : 0.03)))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? accent.fill : Theme.Surface.hairline, lineWidth: isActive ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { builder.activeSide = side }
        .focusable()
        .focused($focus, equals: .area(side))
        .focusEffectDisabled()
        .overlay { focusRing(RoundedRectangle(cornerRadius: 15, style: .continuous), isOn: focus == .area(side)) }
        .onKeyPress(keys: [.space, .return]) { _ in
            builder.activeSide = side
            return .handled
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: side, at: builder.columns(on: side).count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(builder.areaLabel(side))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { builder.activeSide = side }
    }

    private func cardChip(_ column: Int, on side: CSVCardBuilder.Side) -> some View {
        let value = builder.firstValue(column)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(builder.title(column))
                    .font(Theme.Typography.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.TextColor.onAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(accent.fill))
            Text(value.isEmpty ? " " : value.replacingOccurrences(of: "\n", with: " / "))
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: 200, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { perform { $0.remove(column) } }
        .focusable()
        .focused($focus, equals: .cardChip(column))
        .focusEffectDisabled()
        .overlay { focusRing(RoundedRectangle(cornerRadius: 8, style: .continuous), isOn: focus == .cardChip(column)) }
        .onKeyPress(keys: [.space, .return]) { _ in
            perform { $0.remove(column) }
            focus = .area(side)
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let earlier = press.key == .leftArrow
            if press.modifiers.contains(.shift) {
                // ⌘⇧← goes to the front, ⌘⇧→ to the back.
                guard (earlier && side == .back) || (!earlier && side == .front) else { return .handled }
                perform { $0.moveToOtherSide(column) }
            } else {
                perform { earlier ? $0.moveEarlier(column) : $0.moveLater(column) }
            }
            focus = .cardChip(column)
            return .handled
        }
        .draggable(Self.dragPrefix + String(column))
        .dropDestination(for: String.self) { items, _ in
            drop(items, on: side, at: builder.columns(on: side).firstIndex(of: column) ?? 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(builder.cardChipLabel(column))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform { $0.remove(column) } }
        .accessibilityAction(named: "Move earlier") { perform { $0.moveEarlier(column) } }
        .accessibilityAction(named: "Move later") { perform { $0.moveLater(column) } }
        .accessibilityAction(named: "Move to \(side.other.phrase)") { perform { $0.moveToOtherSide(column) } }
    }

    // MARK: The file's columns

    private var columns: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Columns in your file")
            WrapLayout(spacing: 8) {
                ForEach(0..<builder.columnCount, id: \.self) { column in columnChip(column) }
            }
        }
    }

    private func columnChip(_ column: Int) -> some View {
        let canAdd = builder.canAdd(column)
        let isDeck = builder.deckColumn == column
        return HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)
            Text(builder.title(column) + (isDeck ? " · deck" : ""))
                .font(Theme.Typography.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.TextColor.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.Surface.control))
        .opacity(canAdd ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture { perform { $0.add(column) } }
        .focusable()
        .focused($focus, equals: .column(column))
        .focusEffectDisabled()
        .overlay { focusRing(Capsule(), isOn: focus == .column(column)) }
        .onKeyPress(keys: [.space, .return]) { _ in
            perform { $0.add(column) }
            return .handled
        }
        .modifier(DraggableIf(isOn: canAdd, payload: Self.dragPrefix + String(column)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(builder.columnChipLabel(column))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform { $0.add(column) } }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                skipFirstRow
                HairlineDivider()
                deckName
                HairlineDivider()
                menuRow("Deck from a column", selection: Binding(
                    get: { builder.deckColumn },
                    set: { builder.setDeckColumn($0) }
                ))
                HairlineDivider()
                menuRow("Subject from a column", selection: Binding(
                    get: { builder.subjectColumn },
                    set: { builder.setSubjectColumn($0) }
                ))
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.Surface.group))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5)
            }
            if let problem {
                Text(problem)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.problem)
            }
        }
    }

    private var skipFirstRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { builder.hasHeader }, set: { builder.setSkipsFirstRow($0) })) {
                Text("Skip the first row")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
            }
            .toggleStyle(.checkbox)
            .accessibilityHint(builder.firstRowDetail)
            Text(builder.firstRowDetail)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 20)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var deckName: some View {
        if let existingDeckName {
            HStack {
                Text("Adding to “\(existingDeckName)”")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
                Spacer()
                Button("Change…", action: onChangeDestination)
                    .buttonStyle(.capsuleSecondary)
            }
            .padding(.vertical, 8)
        } else {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(builder.deckNameTitle)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.TextColor.primary)
                    Text(builder.deckNameDetail(cardCount: cardCount))
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                TextField(builder.deckNameTitle, text: $builder.deckName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityLabel(builder.deckNameTitle)
            }
            .padding(.vertical, 10)
        }
    }

    private func menuRow(_ title: String, selection: Binding<Int?>) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.TextColor.primary)
            Spacer()
            Picker(title, selection: selection) {
                Text("None").tag(Int?.none)
                ForEach(Array(builder.titles.enumerated()), id: \.offset) { index, name in
                    Text(name).tag(Int?.some(index))
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
        .padding(.vertical, 6)
    }

    /// A thin ring just outside whatever has keyboard focus, quieter than the active side's outline.
    private func focusRing<S: InsettableShape>(_ shape: S, isOn: Bool) -> some View {
        shape
            .inset(by: -3)
            .strokeBorder(Theme.TextColor.primary.with(opacity: isOn ? 0.55 : 0), lineWidth: 1.5)
            .allowsHitTesting(false)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.sectionLabel)
            .foregroundStyle(Theme.TextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Changes

    /// Makes a change and says what happened to VoiceOver.
    private func perform(_ change: (inout CSVCardBuilder) -> String?) {
        guard let announcement = change(&builder) else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private func drop(_ items: [String], on side: CSVCardBuilder.Side, at index: Int) -> Bool {
        guard let item = items.first, item.hasPrefix(Self.dragPrefix),
              let column = Int(item.dropFirst(Self.dragPrefix.count)) else { return false }
        perform { $0.move(column, to: side, at: index) }
        return true
    }
}

/// `.draggable` only while the chip can still be put on the card.
private struct DraggableIf: ViewModifier {
    var isOn: Bool
    var payload: String

    func body(content: Content) -> some View {
        if isOn { content.draggable(payload) } else { content }
    }
}
