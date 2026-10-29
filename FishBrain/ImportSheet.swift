import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where an import was started, so the sheet can file things sensibly.
struct ImportRequest: Identifiable, Equatable {
    let id = UUID()
    /// "Import CSV" on a deck: the cards go to that deck unless the user says otherwise.
    var deckID: Deck.ID?
    /// Started from a subject: new decks and subjects are made inside it.
    var subjectID: Subject.ID?
    /// A file already in hand (dropped on the window).
    var fileURL: URL?
    /// Open the file chooser as soon as the sheet appears.
    var choosesFileAtOnce = false
}

/// "Import": choose or drop a CSV, build the card from its columns (step 1), see what will happen and where
/// it goes (step 2), then do it. The whole import is one undo step.
struct ImportSheet: View {
    var request: ImportRequest
    /// Takes the user to what was made (a deck or a subject).
    var onOpen: (CSVImportPlan.Destination) -> Void
    var onClose: () -> Void

    static let width: CGFloat = 680
    static let contentTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText]
        + [UTType(filenameExtension: "apkg")].compactMap { $0 }

    @EnvironmentObject private var store: DeckStore
    @Environment(\.accentChoice) private var accent

    private enum Stage {
        case choosing(error: String?)
        /// Step 1 of a CSV import: which columns go on the card.
        case buildCard
        /// Step 2 of a CSV import, or an Anki package's only step.
        case preview
        case done(CSVImportPlan)
    }

    private enum Kind { case fromFile, oneDeck, newDeck }

    @State private var stage: Stage = .choosing(error: nil)
    @State private var table: CSVTable?
    @State private var fileName = ""
    /// Step 1's card, the first-row choice and the deck name, kept when going back from step 2.
    @State private var builder: CSVCardBuilder?
    /// Next was pressed with something missing: say what.
    @State private var showsBuildProblem = false
    @State private var kind: Kind = .newDeck
    @State private var chosenDeckID: Deck.ID?
    @State private var skipDuplicates = false
    @State private var isDropTargeted = false
    @State private var showsSkipped = false
    // An Anki package, when that is what was chosen.
    @State private var package: AnkiPackage?
    @State private var overview: AnkiImport.Overview?
    @State private var packageResult: AnkiImport.Result?
    @State private var selectedDecks: Set<Int64> = []
    @State private var fileUnder: Subject.ID?

    var body: some View {
        Group {
            switch stage {
            case .choosing(let error): choosing(error: error)
            case .buildCard: buildCard
            case .preview: if package != nil { packagePreview } else { preview }
            case .done(let plan): done(plan)
            }
        }
        .padding(28)
        .frame(width: Self.width)
        .onAppear {
            chosenDeckID = request.deckID
            if let url = request.fileURL {
                load(url)
            } else if request.choosesFileAtOnce {
                DispatchQueue.main.async { chooseFile() }
            }
        }
    }

    // MARK: Choosing a file

    private func choosing(error: String?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import cards")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text("From a CSV spreadsheet or an Anki package.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            if let error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Status.learning)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Status.learning.with(opacity: 0.12)))
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([".csv", ".tsv", ".txt", ".apkg"], id: \.self) { type in
                        Text(type)
                            .font(Theme.Typography.micro.weight(.semibold))
                            .foregroundStyle(accent.light)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(accent.flippedSurface))
                    }
                }
                Text("Drop a file here")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text("or")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
                Button("Choose File…", action: chooseFile)
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.TextColor.primary.with(opacity: isDropTargeted ? 0.08 : 0.03))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? accent.fill : Theme.TextColor.primary.with(opacity: 0.22),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                    )
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            Text("The file is read on this Mac and nothing is uploaded. You see a preview before any card is added, and ⌘Z undoes the whole import.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.capsuleSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Step 1: build the card

    private var hasHeader: Bool { builder?.hasHeader ?? false }
    private var mapping: CSVColumnMapping { builder?.mapping ?? CSVColumnMapping() }

    /// Step 1's deck name and step 2's "Add to a new deck": one name, so they never disagree.
    private var newDeckName: Binding<String> {
        Binding(get: { builder?.deckName ?? "" }, set: { builder?.deckName = $0 })
    }

    private var builderBinding: Binding<CSVCardBuilder> {
        Binding(
            get: { builder ?? CSVCardBuilder(table: CSVTable(delimiter: .comma, encoding: .utf8, rows: [], brokenRecords: []), fileName: "") },
            set: { new in
                let columnsChanged = new.deckColumn != builder?.deckColumn || new.subjectColumn != builder?.subjectColumn
                builder = new
                if columnsChanged { fitKindToColumns() }
            }
        )
    }

    /// The cards go to a deck that exists, so step 1 shows it instead of asking for a name.
    private var existingDeckName: String? {
        guard effectiveKind == .oneDeck, let deck = store.decks.first(where: { $0.id == chosenDeckID }) else { return nil }
        return deck.name
    }

    private var buildProblem: String? { builder?.problem(needsDeckName: existingDeckName == nil) }

    private var buildCard: some View {
        let plan = plan
        let problem = showsBuildProblem ? buildProblem : nil
        let step = CSVBuildCardStep(
            builder: builderBinding, cardCount: plan.cardCount, existingDeckName: existingDeckName,
            onChangeDestination: { stage = .preview }, problem: problem
        )
        return VStack(alignment: .leading, spacing: 18) {
            fileHeader(step: 1)
            ViewThatFits(in: .vertical) {
                step
                ScrollView { step }.frame(height: 480)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.capsuleSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Next", action: next)
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.defaultAction)
                    .opacity(buildProblem == nil ? 1 : 0.5)
            }
        }
    }

    /// Step 2, unless something is missing from step 1.
    private func next() {
        guard buildProblem == nil else {
            showsBuildProblem = true
            NSAccessibility.post(
                element: NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: buildProblem ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
            return
        }
        showsBuildProblem = false
        stage = .preview
    }

    /// A deck or subject column means making decks from the file; none means one new deck. A deck chosen to
    /// add to stays chosen.
    private func fitKindToColumns() {
        guard kind != .oneDeck else { return }
        kind = (mapping.deck != nil || mapping.subject != nil) ? .fromFile : .newDeck
    }

    // MARK: Step 2: preview and destination

    private var options: CSVImportOptions {
        CSVImportOptions(hasHeader: hasHeader, mapping: mapping, destination: destination, skipDuplicates: skipDuplicates && kind == .oneDeck)
    }

    private var destination: CSVImportDestination {
        switch effectiveKind {
        case .fromFile: .fromFile
        case .oneDeck: chosenDeckID.map { .existingDeck($0) } ?? .newDeck(newDeckName.wrappedValue)
        case .newDeck: .newDeck(newDeckName.wrappedValue)
        }
    }

    private var effectiveKind: Kind {
        if kind == .fromFile, mapping.deck == nil, mapping.subject == nil { return .newDeck }
        if kind == .oneDeck, !store.decks.contains(where: { $0.id == chosenDeckID }) { return .newDeck }
        return kind
    }

    private var plan: CSVImportPlan {
        guard let table else { return CSVImportPlan() }
        return CSVImport.plan(
            table: table, options: options,
            library: Library(subjects: store.subjects, decks: store.decks),
            contextSubjectID: request.subjectID, fileName: newDeckName.wrappedValue.isEmpty ? fileName : newDeckName.wrappedValue
        )
    }

    private var preview: some View {
        let plan = plan
        let reason = importDisabledReason(plan)
        let sections = VStack(alignment: .leading, spacing: 18) {
            previewSection(plan)
            destinationSection(plan)
        }
        return VStack(alignment: .leading, spacing: 18) {
            fileHeader(step: 2)
            // In a short window the sections scroll and the header and the buttons stay put.
            ViewThatFits(in: .vertical) {
                sections
                ScrollView { sections }.frame(height: 440)
            }
            footer(plan, reason: reason)
        }
    }

    private func fileHeader(step: Int) -> some View {
        HStack(spacing: 14) {
            Text(".csv")
                .font(Theme.Typography.micro.weight(.bold))
                .foregroundStyle(accent.light)
                .frame(width: 40, height: 48)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.flippedSurface))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(fileDetail)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            Spacer(minLength: 8)
            Text("Step \(step) of 2")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)
            Button("Choose another…", action: chooseFile)
                .buttonStyle(.capsuleSecondary)
        }
    }

    private var fileDetail: String {
        guard let table else { return "" }
        let rows = table.rows.count - (hasHeader ? 1 : 0) + table.brokenRecords.count
        let separator = table.delimiter.displayName.lowercased()
        let encoding: String
        switch table.encoding {
        case .utf8: encoding = "UTF-8"
        case .utf16: encoding = "UTF-16"
        case .windowsLatin1: encoding = "Windows Latin-1"
        }
        return "\(rows) \(rows == 1 ? "row" : "rows") · \(table.columnCount) \(table.columnCount == 1 ? "column" : "columns") · \(encoding) · \(separator) separated"
    }

    private func previewSection(_ plan: CSVImportPlan) -> some View {
        let more = max(0, plan.rowCount - plan.preview.count)
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Preview")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Goes to").frame(width: 230, alignment: .leading)
                    Text("Front").frame(width: 130, alignment: .leading)
                    Text("Back").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.Typography.micro.weight(.semibold))
                .foregroundStyle(Theme.TextColor.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                ForEach(Array(plan.preview.enumerated()), id: \.offset) { _, row in
                    HairlineDivider()
                    previewRow(row)
                }
                if more > 0 {
                    HairlineDivider()
                    Text("… and \(more) more")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        }
    }

    private func previewRow(_ row: CSVImportPlan.PreviewRow) -> some View {
        HStack(spacing: 10) {
            Text(row.place)
                .foregroundStyle(accent.light)
                .frame(width: 230, alignment: .leading)
            if let problem = row.problem {
                Text("\(problem.text) · skipped (row \(row.rowNumber))")
                    .foregroundStyle(Theme.Status.problem)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(Self.oneLine(row.front))
                    .foregroundStyle(Theme.TextColor.primary)
                    .frame(width: 130, alignment: .leading)
                Text(Self.oneLine(row.back))
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Theme.Typography.footnote)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(row.problem == nil ? Theme.TextColor.primary.with(opacity: 0) : Theme.Status.problem.with(opacity: 0.1))
    }

    /// A side of several lines on one preview row: "to speak / Hablo español."
    static func oneLine(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " / ") }

    private func destinationSection(_ plan: CSVImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Where it goes")
            VStack(spacing: 0) {
                if mapping.deck != nil || mapping.subject != nil {
                    destinationRow(.fromFile, title: "Make decks and subjects from the file", detail: fromFileDetail(plan))
                    HairlineDivider()
                }
                destinationRow(.oneDeck, title: "Add everything to one deck", detail: "Ignores the Deck and Subject columns.") {
                    Picker("Deck", selection: Binding(get: { chosenDeckID }, set: { chosenDeckID = $0; kind = .oneDeck })) {
                        if chosenDeckID == nil { Text("Choose deck").tag(Deck.ID?.none) }
                        ForEach(store.decks) { deck in
                            Text(SubjectPath.text(for: deck, in: store.subjects, limit: 40)).tag(Deck.ID?.some(deck.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(store.decks.isEmpty)
                }
                HairlineDivider()
                destinationRow(.newDeck, title: "Add to a new deck", detail: request.subjectID == nil ? "Named below." : "Made inside this subject.") {
                    TextField("Deck name", text: newDeckName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onTapGesture { kind = .newDeck }
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }

            SettingToggleRow(
                title: "Skip cards that are already in the deck",
                detail: effectiveKind == .oneDeck
                    ? (plan.duplicateCount > 0 ? "\(plan.duplicateCount) with the same front and back are left out." : "Same front and back.")
                    : "Only when adding to a deck that already exists.",
                isOn: $skipDuplicates
            )
            .disabled(effectiveKind != .oneDeck)
            .opacity(effectiveKind == .oneDeck ? 1 : 0.5)
        }
    }

    private func fromFileDetail(_ plan: CSVImportPlan) -> String {
        var parts: [String] = []
        if plan.subjectCount > 0 { parts.append("\(plan.subjectCount) \(plan.subjectCount == 1 ? "subject" : "subjects")") }
        parts.append("\(plan.newDecks.count) \(plan.newDecks.count == 1 ? "deck" : "decks")")
        let made = "Creates " + parts.joined(separator: " and ") + ", new ones even if the names exist."
        if let subjectID = request.subjectID, let subject = store.subjects.first(where: { $0.id == subjectID }) {
            return made + " Filed inside “\(subject.name)”."
        }
        return made
    }

    private func destinationRow<Trailing: View>(
        _ choice: Kind, title: String, detail: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let isOn = effectiveKind == choice
        return HStack(alignment: .top, spacing: 12) {
            Button { kind = choice } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isOn ? accent.light : Theme.TextColor.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Theme.Typography.rowTitle.weight(isOn ? .semibold : .regular))
                            .foregroundStyle(Theme.TextColor.primary)
                        Text(detail)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.TextColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            trailing()
        }
        .padding(.vertical, 10)
    }

    private func importDisabledReason(_ plan: CSVImportPlan) -> String? {
        if !mapping.isUsable { return "Go back and choose a column for the front and for the back." }
        if effectiveKind == .oneDeck, chosenDeckID == nil { return "Choose a deck." }
        if plan.isEmpty { return "No cards were found with these columns." }
        return nil
    }

    private func footer(_ plan: CSVImportPlan, reason: String?) -> some View {
        HStack(spacing: 10) {
            Text(reason ?? plan.summary)
                .font(Theme.Typography.footnote)
                .foregroundStyle(reason == nil ? Theme.TextColor.secondary : Theme.Status.problem)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Back") { stage = .buildCard }
                .buttonStyle(.capsuleSecondary)
            Button("Cancel", action: onClose)
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Import \(plan.cardCount) \(plan.cardCount == 1 ? "card" : "cards")") { perform(plan) }
                .buttonStyle(.capsulePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(reason != nil)
                .opacity(reason == nil ? 1 : 0.5)
        }
    }

    // MARK: Done

    private func done(_ plan: CSVImportPlan) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.Status.ok)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.Status.ok.with(opacity: 0.18)))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Imported \(plan.cardCount) \(plan.cardCount == 1 ? "card" : "cards")")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text(doneSubtitle(plan))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            if !plan.newDecks.isEmpty || !plan.additions.isEmpty {
                VStack(spacing: 0) {
                    let rows = doneRows(plan)
                    ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { index, row in
                        if index > 0 { HairlineDivider() }
                        HStack {
                            Text(row.name).foregroundStyle(Theme.TextColor.primary)
                            Spacer()
                            Text("\(row.count) \(row.count == 1 ? "card" : "cards")").foregroundStyle(Theme.TextColor.secondary)
                        }
                        .font(Theme.Typography.rowTitle)
                        .padding(.vertical, 9)
                    }
                    if rows.count > 6 {
                        HairlineDivider()
                        Text("and \(rows.count - 6) more")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.TextColor.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)
                    }
                }
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
            }
            if !plan.skipped.isEmpty || !plan.notices.isEmpty {
                skippedReport(plan)
            }
            Text("⌘Z in the main window takes back everything this import added.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
            HStack(spacing: 10) {
                Button("Done", action: onClose)
                    .buttonStyle(.capsuleSecondary)
                    .keyboardShortcut(.cancelAction)
                if let target = plan.openTarget {
                    Button(openTitle(for: target)) {
                        onOpen(target)
                        onClose()
                    }
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func doneSubtitle(_ plan: CSVImportPlan) -> String {
        var parts: [String] = []
        if plan.subjectCount > 0 { parts.append("\(plan.subjectCount) \(plan.subjectCount == 1 ? "subject" : "subjects")") }
        if !plan.newDecks.isEmpty { parts.append("\(plan.newDecks.count) new \(plan.newDecks.count == 1 ? "deck" : "decks")") }
        if let first = plan.additions.first, let deck = store.decks.first(where: { $0.id == first.deckID }) {
            parts.append("added to “\(deck.name)”")
        }
        return parts.joined(separator: " · ")
    }

    private func doneRows(_ plan: CSVImportPlan) -> [(name: String, count: Int)] {
        let made = plan.newDecks.map { (name: $0.name, count: $0.cards.count) }
        let added = plan.additions.map { addition in
            (name: store.decks.first { $0.id == addition.deckID }?.name ?? "Deck", count: addition.cards.count)
        }
        return made + added
    }

    private func openTitle(for target: CSVImportPlan.Destination) -> String {
        switch target {
        case .deck(let id): "Open “\(store.decks.first { $0.id == id }?.name ?? "deck")”"
        case .subject(let id): "Open “\(store.subjects.first { $0.id == id }?.name ?? "subject")”"
        }
    }

    private func skippedReport(_ plan: CSVImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showsSkipped.toggle() } label: {
                HStack {
                    Text(reportTitle(plan))
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                    Spacer()
                    Text(showsSkipped ? "Hide" : "Show")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(accent.light)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsSkipped ? "Hides the list" : "Shows which rows and why")
            if showsSkipped {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array((plan.skipped.map(\.text) + plan.notices).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.TextColor.cardBack)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Status.learning.with(opacity: 0.1)))
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { load(url) }
        }
        return true
    }

    /// A CSV, TSV or text file opens on step 1, "Build your card"; an Anki package on its own preview.
    static func opensOnBuildStep(_ url: URL) -> Bool { url.pathExtension.lowercased() != "apkg" }

    private func load(_ url: URL) {
        if !Self.opensOnBuildStep(url) {
            loadPackage(url)
            return
        }
        package = nil
        switch CSVTable.read(contentsOf: url) {
        case .failure(let failure):
            table = nil
            stage = .choosing(error: ImportMessage.failure(failure).message)
        case .success(let loaded):
            table = loaded
            fileName = CSVCardBuilder.deckName(forFile: url)
            builder = CSVCardBuilder(table: loaded, fileName: fileName)
            showsBuildProblem = false
            if request.deckID != nil, store.decks.contains(where: { $0.id == request.deckID }) {
                kind = .oneDeck
                chosenDeckID = request.deckID
            } else {
                kind = .newDeck
                fitKindToColumns()
            }
            stage = .buildCard
        }
    }

    private func perform(_ plan: CSVImportPlan) {
        var final = plan
        if let package, let packageResult {
            // The package's pictures are stored just before the cards that hold them are added.
            AnkiImport.attach(packageResult.pictures, to: &final, package: package, store: store.imageStore)
            if packageResult.soundCount > 0 {
                let n = packageResult.soundCount
                final.notices.insert("\(n) \(n == 1 ? "sound wasn't" : "sounds weren't") imported", at: 0)
            }
        }
        guard store.performImport(final) else { return }
        stage = .done(final)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.sectionLabel)
            .foregroundStyle(Theme.TextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Anki packages

extension ImportSheet {
    fileprivate func reportTitle(_ plan: CSVImportPlan) -> String {
        let unit = package != nil ? "note" : "row"
        let skipped = plan.skipped.count
        let notices = plan.notices.count
        if skipped == 0 { return "\(notices) \(notices == 1 ? "thing" : "things") to know" }
        var title = "\(skipped) \(unit)\(skipped == 1 ? " was" : "s were") skipped"
        if notices > 0 { title += " · \(notices) more \(notices == 1 ? "note" : "notes")" }
        return title
    }

    fileprivate func loadPackage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size > AnkiPackage.maxBytes {
                throw AnkiPackageError.tooLarge(bytes: size, limit: AnkiPackage.maxBytes)
            }
            let loaded = try AnkiPackage(data: Data(contentsOf: url, options: .mappedIfSafe))
            let summary = AnkiImport.overview(of: loaded)
            guard summary.noteCount > 0 else {
                stage = .choosing(error: "This package has no cards in it.")
                return
            }
            table = nil
            package = loaded
            overview = summary
            fileName = url.deletingPathExtension().lastPathComponent
            selectedDecks = Set(summary.decks.map(\.id))
            fileUnder = request.subjectID
            recomputePackage()
            stage = .preview
        } catch let error as AnkiPackageError {
            package = nil
            stage = .choosing(error: AnkiImport.failureMessage(error))
        } catch {
            package = nil
            stage = .choosing(error: AnkiImport.failureMessage(.unreadable(error.localizedDescription)))
        }
    }

    fileprivate func recomputePackage() {
        guard let package else { packageResult = nil; return }
        packageResult = AnkiImport.plan(
            package: package, selectedDeckIDs: selectedDecks,
            library: Library(subjects: store.subjects, decks: store.decks), contextSubjectID: fileUnder
        )
    }

    fileprivate var packagePreview: some View {
        let plan = packageResult?.plan ?? CSVImportPlan()
        let summary = overview
        let reason: String? = plan.isEmpty ? "Tick at least one deck that has cards." : nil
        let sections = VStack(alignment: .leading, spacing: 18) {
            packageDecks(summary)
            packageTypes(summary)
            packageExtras(summary)
            packageDestination
        }
        return VStack(alignment: .leading, spacing: 18) {
            packageHeader(summary)
            ViewThatFits(in: .vertical) {
                sections
                ScrollView { sections }.frame(height: 440)
            }
            packageFooter(plan, reason: reason)
        }
    }

    private func packageHeader(_ summary: Overview?) -> some View {
        HStack(spacing: 14) {
            Text(".apkg")
                .font(Theme.Typography.micro.weight(.bold))
                .foregroundStyle(accent.light)
                .frame(width: 40, height: 48)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.flippedSurface))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName + ".apkg")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary, let package {
                    let size = package.byteCount.formatted(ByteCountFormatStyle(style: .file))
                    Text("\(size) · \(summary.decks.count) \(summary.decks.count == 1 ? "deck" : "decks") · \(summary.noteCount) \(summary.noteCount == 1 ? "note" : "notes") · \(summary.pictureCount) \(summary.pictureCount == 1 ? "picture" : "pictures")")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Choose another…", action: chooseFile)
                .buttonStyle(.capsuleSecondary)
        }
    }

    private func packageDecks(_ summary: Overview?) -> some View {
        let rows = summary?.decks ?? []
        let baseDepth = rows.map(\.depth).min() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                packageLabel("Decks in this package")
                Spacer()
                Text("\(selectedDecks.count) of \(rows.count)")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(accent.light)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { HairlineDivider() }
                    let isOn = selectedDecks.contains(row.id)
                    Button {
                        if isOn { selectedDecks.remove(row.id) } else { selectedDecks.insert(row.id) }
                        recomputePackage()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isOn ? accent.fill : Theme.TextColor.secondary)
                                .accessibilityHidden(true)
                            Text(row.name)
                                .font(Theme.Typography.rowTitle)
                                .foregroundStyle(isOn ? Theme.TextColor.primary : Theme.TextColor.secondary)
                            Spacer(minLength: 8)
                            Text("\(row.noteCount) \(row.noteCount == 1 ? "note" : "notes")")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.TextColor.secondary)
                        }
                        .padding(.leading, 14 + CGFloat(row.depth - baseDepth) * 22)
                        .padding(.trailing, 14)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(row.fullName), \(row.noteCount) notes")
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
            Text("A deck with decks inside becomes a subject. Subjects go three levels deep; anything deeper is joined into the deck’s name.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func packageTypes(_ summary: Overview?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            packageLabel("How cards are brought in")
            VStack(spacing: 0) {
                ForEach(Array((summary?.types ?? []).enumerated()), id: \.element.id) { index, row in
                    if index > 0 { HairlineDivider() }
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(row.name) · \(row.noteCount)")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(row.treatment == .unsupported ? Theme.Status.learning : Theme.TextColor.primary)
                            .frame(width: 190, alignment: .leading)
                        Text(row.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.TextColor.cardBack)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        }
    }

    private func packageExtras(_ summary: Overview?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pictures").font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.TextColor.primary)
                Text("\(summary?.pictureCount ?? 0) found. One per side is kept; extras are listed in the report.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.06)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Not imported").font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.TextColor.primary)
                let sounds = summary?.soundCount ?? 0
                Text("\(sounds) \(sounds == 1 ? "sound" : "sounds"), and any study progress. Every card starts new.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Status.learning.with(opacity: 0.12)))
        }
    }

    private var packageDestination: some View {
        let tree = store.subjectTree
        let options = store.subjects.filter { tree.depth(of: $0.id) ?? Subject.maxDepth < Subject.maxDepth }
        return VStack(alignment: .leading, spacing: 8) {
            packageLabel("File them under")
            HStack {
                Text("Subject")
                    .font(Theme.Typography.rowTitle)
                    .foregroundStyle(Theme.TextColor.primary)
                Spacer()
                Picker("Subject", selection: Binding(
                    get: { fileUnder },
                    set: { fileUnder = $0; recomputePackage() }
                )) {
                    Text("Top level").tag(Subject.ID?.none)
                    ForEach(options) { subject in
                        Text(SubjectPath.text(of: subject.id, in: store.subjects, limit: 40) ?? subject.name).tag(Subject.ID?.some(subject.id))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        }
    }

    private func packageFooter(_ plan: CSVImportPlan, reason: String?) -> some View {
        HStack(spacing: 10) {
            Text(reason ?? packageSummary(plan))
                .font(Theme.Typography.footnote)
                .foregroundStyle(reason == nil ? Theme.TextColor.secondary : Theme.Status.problem)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel", action: onClose)
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Import \(plan.cardCount) \(plan.cardCount == 1 ? "card" : "cards")") { perform(plan) }
                .buttonStyle(.capsulePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(reason != nil)
                .opacity(reason == nil ? 1 : 0.5)
        }
    }

    private func packageSummary(_ plan: CSVImportPlan) -> String {
        plan.summary(skipped: "note")
    }

    private func packageLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.sectionLabel)
            .foregroundStyle(Theme.TextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    fileprivate typealias Overview = AnkiImport.Overview
}
