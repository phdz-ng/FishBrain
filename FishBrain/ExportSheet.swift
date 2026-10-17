import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Export…": choose a format and what is in it, save the file, then Show in Finder or Share. Opened
/// from a deck, a subject or the File menu.
struct ExportSheet: View {
    var target: ExportTarget
    var onClose: () -> Void

    static let width: CGFloat = 560

    @EnvironmentObject private var store: DeckStore
    @Environment(\.accentChoice) private var accent
    @State private var draft: ExportDraft
    @State private var result: Finished?
    @State private var errorMessage: String?

    /// What the done screen shows.
    struct Finished: Equatable {
        var url: URL
        var cards: Int
        var decks: Int
        var bytes: Int
        var leftOutPictures: Int
        var format: ExportFormat
    }

    init(target: ExportTarget, onClose: @escaping () -> Void, initialFormat: ExportFormat = .csv) {
        self.target = target
        self.onClose = onClose
        var draft = ExportDraft(target: target)
        draft.format = initialFormat
        _draft = State(initialValue: draft)
    }

    var body: some View {
        Group {
            if let result {
                done(result)
            } else {
                options
            }
        }
        .padding(28)
        .frame(width: Self.width)
        .alert(
            "The file couldn’t be saved",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Choosing

    private var options: some View {
        let subjects = store.subjects
        let decks = store.decks
        let included = draft.includedDecks(subjects: subjects, decks: decks)
        let cards = included.reduce(0) { $0 + $1.cards.count }
        let reason = draft.unavailableReason(subjects: subjects, decks: decks)
        // Counted from the cards, so the sheet doesn't build a file on every tick.
        let pictures = included.reduce(0) { total, deck in
            total + deck.cards.reduce(0) { $0 + ($1.frontImage == nil ? 0 : 1) + ($1.backImage == nil ? 0 : 1) }
        }

        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text(ExportMessage.summary(cards: cards, decks: included.count))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Format")
                HStack(spacing: 12) {
                    ForEach(ExportFormat.allCases) { format in formatCard(format) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if draft.format == .csv, let notice = ExportMessage.pictureNotice(pictures) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Status.learning)
                        .accessibilityHidden(true)
                    Text("\(Text(notice).fontWeight(.semibold)) \(ExportMessage.pictureAdvice(pictures))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.TextColor.cardBack)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Status.learning.with(opacity: 0.12)))
                .accessibilityElement(children: .combine)
            }

            if draft.format == .csv {
                csvOptions
            } else {
                ankiNotes
            }

            if !draft.structureIsOptional, !draft.rows(subjects: subjects, decks: decks).isEmpty {
                includedDecks(subjects: subjects, decks: decks)
            }

            Text(draft.format == .anki
                ? "Study progress and deck colors aren’t included. Whoever you send this to starts with every card new."
                : "Study progress isn’t included. Whoever you send this to starts with every card new.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)

            footer(cards: cards, reason: reason)
        }
    }

    private var title: String {
        switch target {
        case .deck(let id): "Export “\(store.decks.first { $0.id == id }?.name ?? "deck")”"
        case .subject(let id): "Export “\(store.subjects.first { $0.id == id }?.name ?? "subject")”"
        case .library: "Export your library"
        }
    }

    private func formatCard(_ format: ExportFormat) -> some View {
        let isOn = draft.format == format
        return Button { if format.isAvailable { draft.format = format } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(format.title)
                        .font(Theme.Typography.body.weight(.semibold))
                    Spacer(minLength: 6)
                    Text(".\(format.fileExtension)")
                        .font(Theme.Typography.micro.weight(.semibold))
                        .foregroundStyle(isOn ? accent.light : Theme.TextColor.cardBack)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.TextColor.primary.with(opacity: 0.1)))
                }
                Text(format.summary)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.TextColor.primary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isOn ? accent.flippedSurface : Theme.Surface.control.with(opacity: 0.16)))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? accent.fill : Theme.TextColor.primary.with(opacity: 0), lineWidth: 2)
            }
            .opacity(format.isAvailable ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!format.isAvailable)
        .accessibilityLabel("\(format.title), .\(format.fileExtension)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var csvOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CSV options")
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Separate fields with")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.TextColor.primary)
                        Text("Pick semicolon if your Excel is set to a European language.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.TextColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Picker("Separate fields with", selection: $draft.options.delimiter) {
                        ForEach(CSVDelimiter.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                .padding(.vertical, 10)
                HairlineDivider()
                SettingToggleRow(title: "First row names the columns", detail: "Front, Back", isOn: $draft.options.includesHeader)
                    .padding(.vertical, 10)
                HairlineDivider()
                SettingToggleRow(
                    title: "Add Deck and Subject columns",
                    detail: draft.structureIsOptional
                        ? "Off for one deck. Turn on to keep where it sits when re-importing."
                        : "Always on here, so the file knows which deck and subject each card is in.",
                    isOn: Binding(
                        get: { draft.effectiveOptions.includesStructure },
                        set: { draft.options.includesStructure = $0 }
                    )
                )
                .disabled(!draft.structureIsOptional)
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        }
        .opacity(draft.format == .csv ? 1 : 0.4)
        .disabled(draft.format != .csv)
    }

    /// "Anki package" has no options: what happens to a card, in words.
    private var ankiNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("What is written")
            VStack(alignment: .leading, spacing: 8) {
                ankiNote("Every card is a Basic note with a Front and a Back.")
                ankiNote("Subjects become nested decks, like “Spanish::Grammar::Verbs”.")
                ankiNote("Pictures are included, one per side, with their descriptions.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
        }
    }

    private func ankiNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent.light)
                .padding(.top, 3)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.cardBack)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// " · about 3 MB" for an Anki package, which has pictures; nothing for a CSV.
    private var sizeNote: String {
        guard draft.format == .anki else { return "" }
        let images = store.imageStore
        let bytes = AnkiExport.estimatedBytes(for: draft, subjects: store.subjects, decks: store.decks) { image in
            (try? FileManager.default.attributesOfItem(atPath: images.url(for: image).path)[.size] as? Int) ?? 0
        }
        return " · about \(bytes.formatted(ByteCountFormatStyle(style: .file)))"
    }

    private func includedDecks(subjects: [Subject], decks: [Deck]) -> some View {
        let rows = draft.rows(subjects: subjects, decks: decks)
        let ticked = rows.filter { !draft.excluded.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Included")
                Spacer()
                Text("\(ticked) of \(rows.count) \(rows.count == 1 ? "deck" : "decks")")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(accent.light)
            }
            let list = VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { HairlineDivider() }
                    deckRow(row)
                }
            }
            // About as tall as its rows, up to a height where it scrolls.
            ScrollView { list }
                .frame(height: min(190, CGFloat(rows.count) * 46 + 4))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func deckRow(_ row: ExportDeckRow) -> some View {
        let isOn = !draft.excluded.contains(row.id)
        return Button {
            if isOn { draft.excluded.insert(row.id) } else { draft.excluded.remove(row.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? accent.fill : Theme.TextColor.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(isOn ? Theme.TextColor.primary : Theme.TextColor.secondary)
                    if !row.path.isEmpty {
                        Text(row.path)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.TextColor.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text("\(row.cardCount) \(row.cardCount == 1 ? "card" : "cards")")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.name), \(row.cardCount) \(row.cardCount == 1 ? "card" : "cards")")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func footer(cards: Int, reason: String?) -> some View {
        let fileName = LibraryExport.suggestedFileName(target: target, subjects: store.subjects, decks: store.decks, format: draft.format)
        return HStack(spacing: 10) {
            Text(reason ?? "Saves as \(fileName)\(sizeNote)")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Cancel", action: onClose)
                .buttonStyle(.capsuleSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Export…") { save(suggestedName: fileName) }
                .buttonStyle(.capsulePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(reason != nil)
                .opacity(reason == nil ? 1 : 0.5)
                .help(reason ?? "Choose where to save the file")
        }
    }

    // MARK: Saving

    private func save(suggestedName: String) {
        let data: Data
        let cards: Int
        let decks: Int
        let leftOut: Int
        switch draft.format {
        case .csv:
            let export = LibraryExport.csv(for: draft, subjects: store.subjects, decks: store.decks)
            (data, cards, decks, leftOut) = (export.data, export.cardCount, export.deckCount, export.leftOutPictures)
        case .anki:
            let images = store.imageStore
            do {
                let export = try AnkiExport.package(
                    for: draft, subjects: store.subjects, decks: store.decks,
                    loadPicture: { try? Data(contentsOf: images.url(for: $0)) }
                )
                (data, cards, decks, leftOut) = (export.data, export.cardCount, export.deckCount, export.missingPictures)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        guard cards > 0 else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = draft.format == .csv
            ? [.commaSeparatedText]
            : [UTType(filenameExtension: "apkg")].compactMap { $0 }
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.title = "Export"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            result = Finished(
                url: url, cards: cards, decks: decks, bytes: data.count,
                leftOutPictures: leftOut, format: draft.format
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Done

    private func done(_ result: Finished) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.Status.ok)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.Status.ok.with(opacity: 0.18)))
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(ExportMessage.doneTitle(cards: result.cards))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.TextColor.primary)
                Text(result.decks == 1 ? "1 deck" : "\(result.decks) decks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            HStack(spacing: 14) {
                Text(".\(result.url.pathExtension)")
                    .font(Theme.Typography.micro.weight(.bold))
                    .foregroundStyle(accent.light)
                    .frame(width: 40, height: 48)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.flippedSurface))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.url.lastPathComponent)
                        .font(Theme.Typography.rowTitle.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileDetail(result))
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.Surface.group))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.hairline, lineWidth: 0.5) }
            .accessibilityElement(children: .combine)

            if result.format == .csv, let notice = ExportMessage.pictureNotice(result.leftOutPictures) {
                Text("\(notice) They were left out.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.learning)
                    .multilineTextAlignment(.center)
            } else if result.format == .anki, result.leftOutPictures > 0 {
                let n = result.leftOutPictures
                Text("\(n) \(n == 1 ? "picture couldn’t" : "pictures couldn’t") be read, so \(n == 1 ? "its card went" : "those cards went") without.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.learning)
                    .multilineTextAlignment(.center)
            }
            Text(result.format == .anki
                ? "Send it by AirDrop, Mail, Messages or a USB stick. Open it in Anki, or in FishBrain with File ▸ Import…"
                : "Send it by AirDrop, Mail, Messages or a USB stick. On the other Mac, choose File ▸ Import… to bring its cards in.")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.cardBack)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                    .buttonStyle(.capsuleSecondary)
                ShareLink(item: result.url) { Text("Share…") }
                    .buttonStyle(.capsuleSecondary)
                Button("Done", action: onClose)
                    .buttonStyle(.capsulePrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func fileDetail(_ result: Finished) -> String {
        let size = result.bytes.formatted(ByteCountFormatStyle(style: .file))
        return "\(size) · \(result.url.deletingLastPathComponent().lastPathComponent)"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.sectionLabel)
            .foregroundStyle(Theme.TextColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
