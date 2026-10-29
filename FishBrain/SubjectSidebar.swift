import SwiftUI
import UniformTypeIdentifiers

/// Which top-level subjects are open in the sidebar, remembered between launches.
@MainActor
final class SubjectExpansion: ObservableObject {
    @Published var ids: Set<Subject.ID> {
        didSet { if ids != oldValue { save() } }
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "expandedSubjectIDs") {
        self.defaults = defaults
        self.key = key
        let stored = defaults.stringArray(forKey: key) ?? []
        ids = Set(stored.compactMap(UUID.init(uuidString:)))
    }

    func isExpanded(_ id: Subject.ID) -> Bool { ids.contains(id) }

    func toggle(_ id: Subject.ID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func set(_ id: Subject.ID, expanded: Bool) {
        if expanded { ids.insert(id) } else { ids.remove(id) }
    }

    /// Opens whatever has to be open for `selection` to show in the sidebar.
    func reveal(_ selection: LibrarySelection, subjects: [Subject], decks: [Deck]) {
        let revealed = LibraryOutline.expanded(ids, revealing: selection, subjects: subjects, decks: decks)
        if revealed != ids { ids = revealed }
    }

    private func save() {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

/// Two cards, one behind the other: the glyph for a subject, against a deck's single card.
struct SubjectGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        var path = Path()
        // The card behind: only its top and right edge show.
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 8 * unit, y: rect.minY + 4 * unit, width: 12 * unit, height: 10 * unit),
            cornerSize: CGSize(width: 2 * unit, height: 2 * unit)
        )
        // The card in front.
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 4 * unit, y: rect.minY + 9 * unit, width: 12 * unit, height: 10 * unit),
            cornerSize: CGSize(width: 2 * unit, height: 2 * unit)
        )
        return path
    }
}

/// A subject's icon: the deck icon's rounded square with the two-card glyph.
struct SubjectIcon: View {
    var color: DeckColor
    var size: CGFloat = 22
    var isOnAccent = false

    @Environment(\.accentChoice) private var accent

    var body: some View {
        let glyph = size * 14 / 22
        RoundedRectangle(cornerRadius: size * 6 / 22, style: .continuous)
            .fill(isOnAccent ? Theme.Surface.onAccentIcon : color.fill(accent: accent))
            .frame(width: size, height: size)
            .overlay {
                SubjectGlyph()
                    .stroke(Theme.TextColor.onAccent, style: StrokeStyle(lineWidth: glyph * 2 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: glyph, height: glyph)
            }
            .accessibilityHidden(true)
    }
}

/// A subject in the sidebar: a disclosure arrow for a top-level one, a › at the end for one that opens
/// as a page, the count of everything inside, and a lighter fill with an accent bar when something
/// deeper is open under it.
struct SidebarSubjectRow: View {
    var row: LibraryOutline.SubjectRow
    var onSelect: () -> Void
    var onToggle: () -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        HStack(spacing: 4) {
            if row.isExpandable {
                Button(action: onToggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(row.isSelected ? Theme.TextColor.onAccent : Theme.TextColor.secondary)
                        .frame(width: 18, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse \(row.name)" : "Expand \(row.name)")
            }
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    SubjectIcon(color: row.color, size: row.indent == 0 ? 22 : 20, isOnAccent: row.isSelected)
                    Text(row.name)
                        .font(Theme.Typography.rowTitle.weight(row.isSelected || row.isMarked ? .medium : .regular))
                        .foregroundStyle(row.isSelected ? Theme.TextColor.onAccent : Theme.TextColor.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(row.cardCount)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(row.isSelected ? Theme.TextColor.onAccent : row.isMarked ? Theme.TextColor.cardBack : Theme.TextColor.secondary)
                    if row.opensPage {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(row.isSelected ? Theme.TextColor.onAccent : row.isMarked ? Theme.TextColor.cardBack : Theme.TextColor.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityText)
            .accessibilityHint(row.opensPage ? "Opens the subject" : "Opens the subject and shows what is inside")
        }
        .padding(.leading, row.isExpandable ? 4 : 10)
        .padding(.trailing, 10)
        .frame(minHeight: row.indent == 0 ? 36 : 32)
        .background {
            if row.isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill)
            } else if row.isPicked {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill.with(opacity: 0.4))
            } else if row.isMarked {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill.with(opacity: 0.3))
            }
        }
        .overlay(alignment: .leading) {
            if row.isMarked {
                Capsule().fill(accent.light.color).frame(width: 3, height: 18)
            }
        }
        .padding(.leading, row.indent == 0 ? 0 : 14)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(row.isSelected || row.isPicked ? .isSelected : [])
    }
}

/// A deck in the sidebar, indented one level when it is inside a subject.
struct SidebarDeckRow: View {
    var row: LibraryOutline.DeckRow

    var body: some View {
        SidebarRow(name: row.name, count: row.cardCount, color: row.color, isSelected: row.isSelected, isPicked: row.isPicked)
            .padding(.leading, row.indent == 0 ? 0 : 14)
    }
}

/// "+ New" with a menu: New Deck, New Subject, and the "in <subject>" versions for where you are.
struct NewMenuButton: View {
    var items: [NewMenu.Item]
    var onChoose: (NewMenu.Action) -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if (index == 2 && items.count > 2) || (item.action == .importFile && index != 2) { Divider() }
                Button { onChoose(item.action) } label: {
                    if let shortcut = item.shortcut { Text("\(item.title)    \(shortcut)") } else { Text(item.title) }
                }
                .disabled(!item.isEnabled)
                if let reason = item.disabledReason { Text(reason) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text("New")
                    .font(Theme.Typography.caption.weight(.medium))
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Theme.TextColor.primary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Surface.control))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("New")
        .accessibilityHint("A deck or a subject, or import a file")
    }
}

#if DEBUG
#Preview("Subject rows") {
    let spanish = Subject(name: "Spanish")
    let grammar = Subject(name: "Grammar", parentID: spanish.id)
    let decks = [Deck(name: "Everyday Spanish", cards: [Card(front: "a", back: "b")], subjectID: spanish.id), Deck(name: "World Capitals")]
    let rows = LibraryOutline.rows(
        subjects: [spanish, grammar], decks: decks, expanded: [spanish.id], selection: .subject(spanish.id)
    )
    VStack(alignment: .leading, spacing: 2) {
        ForEach(rows) { row in
            switch row {
            case .header(let header): Text(header.rawValue).font(Theme.Typography.sectionLabel).foregroundStyle(Theme.TextColor.secondary)
            case .subject(let subject): SidebarSubjectRow(row: subject, onSelect: {}, onToggle: {})
            case .deck(let deck): SidebarDeckRow(row: deck)
            }
        }
    }
    .frame(width: 228)
    .appearancePreview()
}
#endif

// MARK: Dragging and moving

extension LibraryItem {
    /// What is carried on the pasteboard while a row is dragged.
    var payload: String {
        switch self {
        case .deck(let id): "fishbrain:deck:\(id.uuidString)"
        case .subject(let id): "fishbrain:subject:\(id.uuidString)"
        }
    }
}

/// Decides, while a row is held over a target, whether letting go would work: the pointer shows
/// not-allowed over one that would be refused.
struct LibraryDropDelegate: DropDelegate {
    var target: DropTarget
    var dragging: () -> LibraryItem?
    var verdict: (LibraryItem, DropTarget) -> LibraryMove.Verdict
    var onHover: (DropTarget?) -> Void
    var onDrop: (LibraryItem, DropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && dragging() != nil
    }

    func dropEntered(info: DropInfo) { onHover(target) }

    func dropExited(info: DropInfo) { onHover(nil) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let item = dragging() else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: verdict(item, target).isAllowed ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { onHover(nil) }
        guard let item = dragging(), verdict(item, target).isAllowed else { return false }
        onDrop(item, target)
        return true
    }
}

/// A row or heading others can be dropped on: highlighted while held over, red with the reason when
/// the drop would be refused.
struct LibraryDropTargetModifier: ViewModifier {
    var target: DropTarget
    var dragging: LibraryItem?
    var hovered: DropTarget?
    var verdict: (LibraryItem, DropTarget) -> LibraryMove.Verdict
    var onHover: (DropTarget?) -> Void
    var onDrop: (LibraryItem, DropTarget) -> Void
    var currentDrag: () -> LibraryItem?

    @Environment(\.accentChoice) private var accent

    private var state: LibraryMove.Verdict? {
        guard hovered == target, let dragging else { return nil }
        return verdict(dragging, target)
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let state {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(state.isAllowed ? accent.light.color : Theme.Status.problem.color, lineWidth: 2)
                        if let reason = state.reason {
                            // A short tooltip in place of the row while it is being refused.
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.Surface.notch.color).opacity(0.94)
                            Text(reason)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Status.problem.color)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 8)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .help(state?.reason ?? "")
            .onDrop(of: [.plainText], delegate: LibraryDropDelegate(
                target: target, dragging: currentDrag, verdict: verdict, onHover: onHover, onDrop: onDrop
            ))
    }
}

/// "Move to…": the places the item may go, as a submenu tree. Places it may not go are not in it.
struct MoveToMenu: View {
    var destinations: LibraryMove.Destinations
    var onMove: (Subject.ID?) -> Void

    var body: some View {
        if !destinations.isEmpty {
            Menu("Move to…") {
                if let unfile = destinations.unfile {
                    Button(unfile.title) { onMove(nil) }
                    if !destinations.subjects.isEmpty { Divider() }
                }
                ForEach(destinations.subjects) { destination in
                    DestinationItem(destination: destination, onMove: onMove)
                }
            }
        }
    }

    /// A subject is a button when nothing is inside it to pick, a submenu otherwise (with "this one" first).
    private struct DestinationItem: View {
        var destination: LibraryMove.Destination
        var onMove: (Subject.ID?) -> Void

        var body: some View {
            if destination.children.isEmpty {
                Button(destination.title) { onMove(destination.subjectID) }
            } else {
                Menu(destination.title) {
                    if destination.isTarget {
                        Button(destination.title) { onMove(destination.subjectID) }
                        Divider()
                    }
                    ForEach(destination.children) { child in
                        DestinationItem(destination: child, onMove: onMove)
                    }
                }
            }
        }
    }
}
