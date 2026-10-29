import SwiftUI

/// Frosted sidebar on the left, the selected deck on the right.
struct MainWindowView: View {
    static let minimumSize = CGSize(width: 920, height: 480)
    static let sidebarWidth: CGFloat = 240

    @EnvironmentObject private var store: DeckStore
    @EnvironmentObject private var playback: PlaybackStore
    @EnvironmentObject private var study: StudyStore
    @EnvironmentObject private var runHistory: RunHistoryStore
    @EnvironmentObject private var clock: StudyClockGate
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var composer: ComposerModel
    @State private var isShowingWelcome = false
    @State private var playbackWatcher: DirectoryWatcher?
    @ObservedObject private var router = DeepLinkRouter.shared
    @Environment(\.accentChoice) private var accent
    @State private var selection: Deck.ID?
    /// A subject's page is showing instead of a deck.
    @State private var selectedSubjectID: Subject.ID?
    @State private var isRenamingSubject = false
    /// Which top-level subjects are open in the sidebar, remembered between launches.
    @StateObject private var expansion = SubjectExpansion()
    /// The Create with AI screen is showing instead of a deck.
    @State private var showsComposer = false
    /// The deck being gone through in Learn mode, which takes over the whole window.
    @State private var learningDeckID: Deck.ID?
    /// A subject being gone through with Learn all: every deck inside it, one after another.
    @State private var learningSubjectID: Subject.ID?
    /// The Review sprint setup sheet, opened from a deck's Review button.
    @State private var isShowingReviewSetup = false
    @State private var reviewSetupDeckID: Deck.ID?
    /// What the sheet opens with ticked.
    @State private var reviewSetupTicked: Set<Deck.ID>?
    /// The decks ticked when a sprint was last started: remembered for this launch only.
    @State private var lastReviewTicked: Set<Deck.ID> = []
    /// Rows chosen along with others (⌘-click, Shift-click) for "Review N decks". The page that is open
    /// doesn't change.
    @State private var pickedItems: Set<LibraryItem> = []
    @State private var pickAnchor: LibrarySelection?
    /// The Review sprint on screen (running, then its results), which takes over the whole window.
    @State private var sprint: ReviewSprintModel?
    /// A sprint waiting for a yes, because a notch session is running and would be ended by it.
    @State private var pendingSprint: PendingSprint?
    @State private var isRenaming = false
    @State private var deckPendingDeletion: Deck?
    @State private var subjectPendingDeletion: Subject?
    @Environment(\.undoManager) private var undoManager
    @State private var cardFocusRequest: Card.ID?
    @State private var isPastingCards = false
    /// What the Import sheet is open on, or nil.
    @State private var importRequest: ImportRequest?
    /// What the Export sheet is open on, or nil.
    @State private var exportTarget: ExportTarget?
    @State private var query = ""
    /// The card chosen from the search results; scrolled to and highlighted in its deck.
    @State private var highlightedCardID: Card.ID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let selected = DeckSelection.resolve(selection, in: store.decks)
        let results = CardSearch.search(query, in: store.decks, subjects: store.subjects)
        Group {
            if let sprint {
                ReviewSprintView(
                    model: sprint,
                    onSameMix: { requestSprint(.mix(sprint.setup)) },
                    onFollowUp: { requestSprint(.followUp($0, sprint.setup)) },
                    onDone: { self.sprint = nil }
                )
                .id(ObjectIdentifier(sprint))
            } else if let subject = learningSubject, !learningSubjectDecks.isEmpty {
                LearnView(title: subject.name, decks: learningSubjectDecks, isWholeSubject: true) { learningSubjectID = nil }
                    .id(subject.id)
            } else if let learning = learningDeck {
                LearnView(deck: learning) { learningDeckID = nil }
                    .id(learning.id)
            } else {
                HStack(spacing: 0) {
                    sidebar(selected: selected, results: results, searchFocus: $isSearchFocused)
                    Rectangle().fill(Theme.Surface.hairline).frame(width: 0.5)
                    detail(for: selected)
                }
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        // The hidden title bar is a top safe-area inset; without ignoring it the backgrounds stop
        // below it and the clear window shows the desktop through the strip.
        .background { Rectangle().fill(Theme.Surface.window).ignoresSafeArea() }
        .background { FrostedWindowBackground().ignoresSafeArea() }
        .background { WindowConfigurator() }
        // A CSV dropped on the window opens the Import sheet on it. Pictures dropped on a card are taken
        // by the card first; anything else that isn't a CSV is ignored.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard importRequest == nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ImportFile.isImportable(url) else { return }
                DispatchQueue.main.async {
                    if importRequest == nil { importRequest = ImportRequest(subjectID: currentSubject?.id, fileURL: url) }
                }
            }
            return true
        }
        .alert(
            "A notch session is running",
            isPresented: Binding(get: { pendingSprint != nil }, set: { if !$0 { pendingSprint = nil } })
        ) {
            Button("Keep session", role: .cancel) { pendingSprint = nil }
            Button("End it, start sprint") {
                if let pending = pendingSprint {
                    clock.endSessionForSprint(at: Date())
                    begin(pending)
                }
            }
        } message: {
            Text(sessionConfirmation)
        }
        // Quitting ends a sprint in progress, and keeps what it did.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            sprint?.endForQuit()
        }
        .sheet(isPresented: $isShowingReviewSetup) {
            ReviewSetupSheet(
                initialDeckID: reviewSetupDeckID, initialTicked: reviewSetupTicked, currentSubjectID: currentSubject?.id,
                minutes: settings.reviewMinutes,
                history: runHistory.history.resultsHistory,
                onStart: { setup in
                    isShowingReviewSetup = false
                    requestSprint(.mix(setup))
                },
                onCancel: { isShowingReviewSetup = false }
            )
            .environment(\.accentChoice, accent)
        }
        .sheet(item: $importRequest) { request in
            ImportSheet(request: request, onOpen: { target in
                switch target {
                case .deck(let id): openDeck(id)
                case .subject(let id): openSubject(id, expanding: true)
                }
            }, onClose: { importRequest = nil })
            .environment(\.accentChoice, accent)
        }
        .sheet(item: $exportTarget) { target in
            ExportSheet(target: target) { exportTarget = nil }
                .environment(\.accentChoice, accent)
        }
        .sheet(isPresented: $isPastingCards) {
            if let deck = selected {
                PasteCardsSheet(
                    deckName: deck.name,
                    onAdd: { cards in
                        store.addCards(cards, to: deck.id)
                        isPastingCards = false
                    },
                    onCancel: { isPastingCards = false }
                )
                .environment(\.accentChoice, accent)
            }
        }
        // A widget asked to open a deck.
        .onReceive(router.$pendingDeckID) { id in
            guard let id else { return }
            openDeck(id)
            query = ""
            router.pendingDeckID = nil
        }
        .modifier(MainWindowEntryPoints(
            router: router, exportAvailable: exportAvailable, selectedSubjectID: selectedSubjectID,
            onImportURL: { importRequest = ImportRequest(subjectID: currentSubject?.id, fileURL: $0) },
            onCommandsChanged: { registerCommands(selectedDeckID: selected?.id) }
        ))
        .onOpenURL { DeepLinkRouter.shared.handle($0) }
        // Clearing the search returns to the normal view.
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { highlightedCardID = nil }
        }
        // New Deck, Add Card and Find Cards in the menus, with their shortcuts.
        .onAppear {
            // Undo for moving and deleting decks and subjects goes through the window's own.
            store.undoManager = undoManager
            registerCommands(selectedDeckID: selected?.id)
            if !settings.hasSeenWelcome { isShowingWelcome = true }
            #if DEBUG
            // `-FishBrainShowComposer` opens Create with AI at launch, for looking at it.
            if ProcessInfo.processInfo.arguments.contains("-FishBrainShowComposer") {
                showsComposer = true
                isShowingWelcome = false
            }
            #endif
        }
        .onChange(of: undoManager) { _, manager in store.undoManager = manager }
        .onChange(of: selected?.id) { _, id in
            registerCommands(selectedDeckID: id)
            // Another deck was picked (or this one was deleted): Learn is over.
            if learningDeckID != id { learningDeckID = nil }
            learningSubjectID = nil
        }
        .onDisappear { CommandCenter.shared.clear() }
        // Picks up skips and flips made in the widget or notch. The kernel reports the shared folder
        // changing, so nothing polls; coming back to the app also re-reads, in case an event was missed.
        .onAppear {
            playbackWatcher = DirectoryWatcher(directory: AppGroup.storageDirectory()) {
                MainActor.assumeIsolated {
                    playback.refresh()
                    study.refresh()
                }
            }
        }
        .onDisappear {
            playbackWatcher?.cancel()
            playbackWatcher = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            playback.refresh()
            study.refresh()
        }
        .alert(
            subjectPendingDeletion.map { LibraryMove.DeletionPlan(subject: $0, subjects: store.subjects, decks: store.decks).title } ?? "",
            isPresented: Binding(get: { subjectPendingDeletion != nil }, set: { if !$0 { subjectPendingDeletion = nil } }),
            presenting: subjectPendingDeletion
        ) { subject in
            let plan = LibraryMove.DeletionPlan(subject: subject, subjects: store.subjects, decks: store.decks)
            if plan.isEmpty {
                Button("Delete", role: .destructive) { delete(subject, deletingContents: false) }
            } else {
                Button(LibraryMove.DeletionPlan.moveUpTitle) { delete(subject, deletingContents: false) }
                    .keyboardShortcut(.defaultAction)
                Button(plan.deleteAllTitle, role: .destructive) { delete(subject, deletingContents: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { subject in
            Text(LibraryMove.DeletionPlan(subject: subject, subjects: store.subjects, decks: store.decks).message)
        }
        .alert(
            "Delete “\(deckPendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { deckPendingDeletion != nil }, set: { if !$0 { deckPendingDeletion = nil } }),
            presenting: deckPendingDeletion
        ) { deck in
            Button("Delete", role: .destructive) {
                store.deleteDeck(deck.id)
                isRenaming = false
            }
            Button("Cancel", role: .cancel) {}
        } message: { deck in
            Text(DeckSummary.deleteConfirmation(cardCount: deck.cards.count))
        }
    }

    /// Only one study clock runs at a time: with a notch session running, ask before ending it.
    private func requestSprint(_ pending: PendingSprint) {
        switch clock.requestSprintStart(at: Date()) {
        case .allowed: begin(pending)
        case .needsConfirmation: pendingSprint = pending
        }
    }

    /// What the confirmation says: how much of the session is left and that its cards are kept.
    private var sessionConfirmation: String {
        if case .needsConfirmation(let info) = clock.requestSprintStart(at: Date()) {
            return StudyClockGate.confirmationText(for: info, at: Date())
        }
        return "Starting a sprint ends it and keeps its cards."
    }

    /// Builds the queue from the setup's ticked decks as they are now, and takes over the window.
    private func begin(_ pending: PendingSprint) {
        pendingSprint = nil
        learningDeckID = nil
        learningSubjectID = nil
        let model: ReviewSprintModel
        switch pending {
        case .mix(let setup):
            lastReviewTicked = setup.ticked
            settings.reviewMinutes = setup.minutes
            model = ReviewSprintModel.start(
                setup: setup, decks: { store.decks }, playback: { playback.states }, grader: sprintGrader,
                history: runHistory.history.resultsHistory, onFinished: finishedSprint, onClock: reportSprintClock
            )
        case .followUp(let results, let setup):
            model = ReviewSprintModel.followUp(
                from: results, setup: setup, decks: { store.decks }, playback: { playback.states }, grader: sprintGrader,
                history: runHistory.history.resultsHistory, onFinished: finishedSprint, onClock: reportSprintClock
            )
        }
        clock.sprintStarted(model.clockInfo, at: Date())
        sprint = model
    }

    /// A finished sprint goes into the history (which saving can't make fail) and, as the recap and
    /// "Last: N cards", to the notch, the same place a session's result goes.
    private var finishedSprint: (RunRecord?) -> Void {
        { [runHistory, clock] record in
            if let record { runHistory.record(record) }
            clock.sprintEnded(record.map { StudySession.Result(reviewed: $0.reviewed, minutes: $0.minutes, endedAt: Date()) })
        }
    }

    private var reportSprintClock: (StudyClockInfo) -> Void {
        { [clock] info in clock.sprintChanged(info) }
    }

    /// Grades go to the shared playback file by card, so the rotation the widget and notch follow is untouched.
    private var sprintGrader: (ReviewGrade, Card.ID, Deck, Date) -> Void {
        { [playback] grade, cardID, deck, date in playback.grade(grade, cardID: cardID, in: deck, at: date) }
    }

    private var learningSubject: Subject? {
        learningSubjectID.flatMap { id in store.subjects.first { $0.id == id } }
    }

    /// Every deck inside the subject being learned, sub-subjects included, in the order the sidebar lists them.
    private var learningSubjectDecks: [Deck] {
        guard let id = learningSubjectID else { return [] }
        return store.subjectTree.decksInOutlineOrder(of: id, among: store.decks)
    }

    private var learningDeck: Deck? {
        learningDeckID.flatMap { id in store.decks.first { $0.id == id } }
    }

    /// What the window is showing, as the outline sees it.
    private var librarySelection: LibrarySelection? {
        if showsComposer { return nil }
        if let subject = currentSubject { return .subject(subject.id) }
        return DeckSelection.resolve(selection, in: store.decks).map { .deck($0.id) }
    }

    private var currentSubject: Subject? {
        selectedSubjectID.flatMap { id in store.subjects.first { $0.id == id } }
    }

    /// Where "New ... in" goes: the open subject, or the subject holding the open deck.
    private var newMenuContext: Subject.ID? {
        if let subject = currentSubject { return subject.id }
        return DeckSelection.resolve(selection, in: store.decks)?.subjectID
    }

    /// The search field, the Create with AI row, the subjects and decks, and the New menu.
    private func sidebar(selected: Deck?, results: [CardSearchResult], searchFocus: FocusState<Bool>.Binding) -> some View {
        let rows = LibraryOutline.rows(
            subjects: store.subjects, decks: store.decks, expanded: expansion.ids,
            selection: librarySelection, playback: playback.states, picked: pickedItems
        )
        let pickedDecks = LibraryOutline.deckIDs(for: pickedItems, subjects: store.subjects, decks: store.decks)
        return SidebarView(
            rows: rows,
            decks: store.decks,
            subjects: store.subjects,
            hasLibrary: !store.decks.isEmpty || !store.subjects.isEmpty,
            query: $query,
            results: results,
            highlightedCardID: highlightedCardID,
            isComposerSelected: showsComposer,
            composerBadge: composer.draftBadge,
            isSearchFocused: searchFocus,
            newMenuItems: NewMenu.items(in: newMenuContext, tree: store.subjectTree) + [NewMenu.importItem],
            onSelectResult: { result in
                openDeck(result.deckID)
                highlightedCardID = result.id
            },
            onSelectDeck: { click(.deck($0), rows: rows) },
            onSelectSubject: { click(.subject($0), rows: rows) },
            reviewSelectionTitle: pickedDecks.isEmpty ? nil : LibraryOutline.reviewTitle(deckCount: pickedDecks.count),
            onReviewSelection: { openReviewSetup(deckID: nil, ticked: pickedDecks) },
            onClearPicked: { pickedItems = []; pickAnchor = nil },
            onToggleSubject: { expansion.toggle($0) },
            onSelectComposer: {
                showsComposer = true
                isRenaming = false
                isRenamingSubject = false
                highlightedCardID = nil
            },
            onNew: choose,
            onMove: { step in
                guard let next = LibraryOutline.neighbor(of: librarySelection, in: rows, step: step) else { return }
                switch next {
                case .deck(let id): openDeck(id)
                case .subject(let id): openSubject(id, expanding: false)
                }
            },
            onExpand: { expanded in
                if case .subject(let id)? = librarySelection, store.subjectTree.subject(id)?.parentID == nil {
                    expansion.set(id, expanded: expanded)
                }
            },
            onRenameDeck: { openDeck($0); isRenaming = true },
            onSetDeckColor: { store.setColor($1, for: $0) },
            onDeleteDeck: { id in deckPendingDeletion = store.decks.first { $0.id == id } },
            onRenameSubject: { openSubject($0, expanding: false); isRenamingSubject = true },
            onSetSubjectColor: { store.setColor($1, forSubject: $0) },
            onDeleteSubject: { id in subjectPendingDeletion = store.subjects.first { $0.id == id } },
            onExportDeck: { exportTarget = .deck($0) },
            onExportSubject: { exportTarget = .subject($0) },
            onImportSubject: { importRequest = ImportRequest(subjectID: $0) },
            exportReason: { exportReason(for: $0) },
            verdict: { LibraryMove.verdict(moving: $0, to: $1, subjects: store.subjects, decks: store.decks) },
            onDrop: { item, target in
                switch target {
                case .subject(let id): moveItem(item, to: id)
                case .subjectsHeading, .decksHeading: moveItem(item, to: nil)
                }
            },
            destinations: { LibraryMove.destinations(for: $0, subjects: store.subjects, decks: store.decks) },
            onMoveItem: moveItem
        )
        .frame(width: Self.sidebarWidth)
        .background { Rectangle().fill(accent.sidebar).ignoresSafeArea() }
        .sheet(isPresented: $isShowingWelcome) {
            WelcomeSheet(
                hasGettingStartedDeck: store.decks.contains { $0.name == GettingStarted.deckName },
                onDismiss: {
                    settings.hasSeenWelcome = true
                    isShowingWelcome = false
                }
            )
            .environment(\.accentChoice, accent)
        }
    }

    // MARK: Moving about the library

    /// A click on a sidebar row. ⌘-click adds it to the rows chosen for a review, or takes it out; Shift-click
    /// chooses the run of rows from the last one clicked; neither changes the page that is open. A plain
    /// click clears the choice and opens the row.
    private func click(_ selection: LibrarySelection, rows: [LibraryOutline.Row]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if pickedItems.isEmpty, let open = librarySelection { pickedItems = [open.item] }
            if pickedItems.contains(selection.item) { pickedItems.remove(selection.item) } else { pickedItems.insert(selection.item) }
            pickAnchor = selection
        } else if flags.contains(.shift) {
            let anchor = pickAnchor ?? librarySelection ?? selection
            pickedItems = Set(LibraryOutline.range(from: anchor, to: selection, in: rows).map(\.item))
            pickAnchor = anchor
        } else {
            pickedItems = []
            pickAnchor = selection
            switch selection {
            case .deck(let id): openDeck(id)
            case .subject(let id): openSubject(id, expanding: true)
            }
        }
    }

    /// Opens the Review sprint sheet: with `ticked` if given, otherwise the mix chosen last time in this launch
    /// when it includes the deck you came from, otherwise just that deck.
    private func openReviewSetup(deckID: Deck.ID?, ticked: Set<Deck.ID>? = nil) {
        reviewSetupDeckID = deckID
        reviewSetupTicked = ticked ?? ReviewSetup.startingTicked(
            remembered: lastReviewTicked, deckID: deckID, existing: Set(store.decks.map(\.id))
        )
        isShowingReviewSetup = true
    }

    /// Shows a deck (opening the subjects it is inside, so it shows in the sidebar).
    private func openDeck(_ id: Deck.ID) {
        selection = id
        selectedSubjectID = nil
        showsComposer = false
        isRenaming = false
        isRenamingSubject = false
        highlightedCardID = nil
        expansion.reveal(.deck(id), subjects: store.subjects, decks: store.decks)
    }

    /// Shows a subject's page. Choosing a top-level subject in the sidebar also opens it.
    private func openSubject(_ id: Subject.ID, expanding: Bool) {
        selectedSubjectID = id
        showsComposer = false
        isRenaming = false
        isRenamingSubject = false
        highlightedCardID = nil
        expansion.reveal(.subject(id), subjects: store.subjects, decks: store.decks)
        if expanding, store.subjectTree.subject(id)?.parentID == nil { expansion.set(id, expanded: true) }
    }

    /// Files a deck or a subject somewhere (nil: no subject, or the top level). What was open stays open,
    /// and the sidebar opens whatever it has to to show it.
    private func moveItem(_ item: LibraryItem, to subjectID: Subject.ID?) {
        switch item {
        case .deck(let id):
            guard store.moveDeck(id, to: subjectID) else { return }
            expansion.reveal(.deck(id), subjects: store.subjects, decks: store.decks)
        case .subject(let id):
            guard store.moveSubject(id, into: subjectID) else { return }
            expansion.reveal(.subject(id), subjects: store.subjects, decks: store.decks)
            if let subjectID { expansion.set(subjectID, expanded: true) }
        }
    }

    /// Deletes a subject, keeping what is inside it (moved up one level) or taking it too, and leaves
    /// the window on something that still exists.
    private func delete(_ subject: Subject, deletingContents: Bool) {
        let outcome = LibraryMove.selectionAfterDeleting(
            subject, deletingContents: deletingContents, current: librarySelection, subjects: store.subjects, decks: store.decks
        )
        if deletingContents { store.deleteSubjectAndContents(subject.id) } else { store.deleteSubject(subject.id) }
        expansion.ids.remove(subject.id)
        switch outcome {
        case .unchanged:
            break
        case .select(let selection):
            switch selection {
            case .deck(let id): openDeck(id)
            case .subject(let id): openSubject(id, expanding: false)
            }
        case .firstRow:
            let rows = LibraryOutline.rows(subjects: store.subjects, decks: store.decks, expanded: expansion.ids, selection: nil)
            switch LibraryOutline.neighbor(of: nil, in: rows, step: 1) {
            case .deck(let id)?: openDeck(id)
            case .subject(let id)?: openSubject(id, expanding: false)
            case nil:
                selectedSubjectID = nil
                selection = nil
            }
        }
    }

    /// An item of the New menu, in the sidebar or on a subject's page.
    private func choose(_ action: NewMenu.Action) {
        switch action {
        case .newDeck: newDeck()
        case .newSubject: newSubject(in: nil)
        case .newDeckIn(let id): newDeck(in: id)
        case .newSubjectIn(let id): newSubject(in: id)
        case .importFile: importRequest = ImportRequest(subjectID: newMenuContext)
        }
    }

    /// The Create with AI form, or the selected deck.
    @ViewBuilder
    private func detail(for selected: Deck?) -> some View {
        if showsComposer {
            Group {
                if let draft = composer.draft {
                    DraftView(draft: draft) { deckID in
                        openDeck(deckID)
                    }
                } else {
                    ComposerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let subject = currentSubject {
            SubjectPageView(
                subject: subject,
                isRenaming: $isRenamingSubject,
                onOpenSubject: { openSubject($0, expanding: false) },
                onOpenDeck: { openDeck($0) },
                onNewDeck: { newDeck(in: $0) },
                onNewSubject: { newSubject(in: $0) },
                onLearn: { learningDeckID = $0 },
                onReview: { openReviewSetup(deckID: $0) },
                onLearnSubject: { learningSubjectID = $0 },
                onReviewSubject: { id in
                    // Every deck inside it ticked, sub-subjects too.
                    let decks = store.subjectTree.decksInOutlineOrder(of: id, among: store.decks)
                    openReviewSetup(deckID: nil, ticked: Set(decks.map(\.id)))
                },
                onRename: { store.renameSubject(subject.id, to: $0) },
                onSetColor: { store.setColor($0, forSubject: subject.id) },
                destinations: LibraryMove.destinations(for: .subject(subject.id), subjects: store.subjects, decks: store.decks),
                onMoveTo: { moveItem(.subject(subject.id), to: $0) },
                onDelete: { subjectPendingDeletion = subject },
                onExport: { exportTarget = .subject(subject.id) },
                onImport: { importRequest = ImportRequest(subjectID: subject.id) },
                exportReason: exportReason(for: .subject(subject.id)),
                appearance: $settings.appearance
            )
            .id(subject.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DeckContentView(
                deck: selected,
                breadcrumb: breadcrumb(for: selected),
                onOpenSubject: { openSubject($0, expanding: false) },
                isRenaming: $isRenaming,
                cardFocusRequest: $cardFocusRequest,
                highlightedCardID: highlightedCardID,
                onRename: { if let id = selected?.id { store.renameDeck(id, to: $0) } },
                onSetColor: { if let id = selected?.id { store.setColor($0, for: id) } },
                onNewDeck: { newDeck() },
                onAddCard: {
                    if let id = selected?.id, let card = store.addCard(to: id) { cardFocusRequest = card.id }
                },
                onImportCSV: { importRequest = ImportRequest(deckID: selected?.id, choosesFileAtOnce: true) },
                onPasteCards: { isPastingCards = true },
                onExport: { if let id = selected?.id { exportTarget = .deck(id) } },
                exportReason: selected.flatMap { exportReason(for: .deck($0.id)) },
                onLearn: { if let id = selected?.id { learningDeckID = id } },
                onReview: { openReviewSetup(deckID: selected?.id) },
                onGenerate: {
                    guard let id = selected?.id, composer.prepareForDeck(id) else { return }
                    showsComposer = true
                },
                generateAvailability: composer.deckGenerateAvailability
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func registerCommands(selectedDeckID: Deck.ID?) {
        let center = CommandCenter.shared
        center.newDeck = { newDeck() }
        center.newSubject = { newSubject(in: nil) }
        center.showWelcome = { isShowingWelcome = true }
        center.addGettingStarted = {
            let deck = store.add(GettingStarted.deck())
            openDeck(deck.id)
        }
        center.focusSearch = { isSearchFocused = true }
        // Dimmed in the File menu while there is nothing to export, as the menus on a deck or subject are.
        center.exportSelection = exportAvailable ? { exportTarget = currentExportTarget } : nil
        center.importFile = { importRequest = ImportRequest(subjectID: currentSubject?.id) }
        center.createWithAI = {
            learningDeckID = nil
            learningSubjectID = nil
            query = ""
            highlightedCardID = nil
            isRenaming = false
            isRenamingSubject = false
            showsComposer = true
        }
        center.addCard = selectedDeckID.map { id in
            { if let card = store.addCard(to: id) { cardFocusRequest = card.id } }
        }
    }

    private func exportReason(for target: ExportTarget) -> String? {
        ExportDraft(target: target).unavailableReason(subjects: store.subjects, decks: store.decks)
    }

    /// What File ▸ Export… covers: the open subject, else the open deck, else the whole library.
    private var currentExportTarget: ExportTarget {
        .current(
            subjectID: currentSubject?.id,
            deckID: DeckSelection.resolve(selection, in: store.decks)?.id
        )
    }

    private var exportAvailable: Bool {
        exportReason(for: currentExportTarget) == nil
    }

    /// Creates a deck (in a subject, if one is given), selects it and puts its name in edit mode.
    private func newDeck(in subjectID: Subject.ID? = nil) {
        let deck = store.addDeck()
        if let subjectID { store.moveDeck(deck.id, to: subjectID) }
        openDeck(deck.id)
        isRenaming = true
    }

    /// Creates a subject (inside another, if one is given), opens its page and puts its name in edit
    /// mode, as New Deck does. Nothing happens where it would be a fourth level.
    private func newSubject(in parentID: Subject.ID?) {
        guard let subject = store.addSubject(parentID: parentID) else { return }
        openSubject(subject.id, expanding: false)
        isRenamingSubject = true
    }

    /// The subjects a deck is inside, outermost first, for the breadcrumb above its title.
    private func breadcrumb(for deck: Deck?) -> [Subject] {
        guard let subjectID = deck?.subjectID, let subject = store.subjectTree.subject(subjectID) else { return [] }
        return Array(store.subjectTree.ancestors(of: subjectID).reversed()) + [subject]
    }
}

/// A sprint waiting to start, once a running notch session has been dealt with.
enum PendingSprint: Equatable {
    case mix(ReviewSetup)
    case followUp(ReviewResults, ReviewSetup)
}

struct SidebarView: View {
    var rows: [LibraryOutline.Row]
    /// Every deck, wherever it is filed, and the subjects: what the footer's notch picker lists.
    var decks: [Deck]
    var subjects: [Subject] = []
    /// Whether there is anything to list; without it the list says so.
    var hasLibrary: Bool
    @Binding var query: String
    var results: [CardSearchResult]
    var highlightedCardID: Card.ID?
    var isComposerSelected = false
    /// What the Create with AI row says about a draft: "9/20", "Draft".
    var composerBadge: String?
    var isSearchFocused: FocusState<Bool>.Binding
    var newMenuItems: [NewMenu.Item]
    var onSelectResult: (CardSearchResult) -> Void
    var onSelectDeck: (Deck.ID) -> Void
    var onSelectSubject: (Subject.ID) -> Void
    /// "Review 3 decks" while several rows are chosen; nil when none are.
    var reviewSelectionTitle: String?
    var onReviewSelection: () -> Void = {}
    var onClearPicked: () -> Void = {}
    var onToggleSubject: (Subject.ID) -> Void
    var onSelectComposer: () -> Void = {}
    var onNew: (NewMenu.Action) -> Void
    /// Up (-1) and Down (1) through the visible rows.
    var onMove: (Int) -> Void
    /// Right (true) opens the selected subject, Left (false) closes it.
    var onExpand: (Bool) -> Void
    var onRenameDeck: (Deck.ID) -> Void
    var onSetDeckColor: (Deck.ID, DeckColor) -> Void
    var onDeleteDeck: (Deck.ID) -> Void
    var onRenameSubject: (Subject.ID) -> Void
    var onSetSubjectColor: (Subject.ID, DeckColor) -> Void
    var onDeleteSubject: (Subject.ID) -> Void = { _ in }
    var onExportDeck: (Deck.ID) -> Void = { _ in }
    var onExportSubject: (Subject.ID) -> Void = { _ in }
    var onImportSubject: (Subject.ID) -> Void = { _ in }
    /// Why Export… is off for a deck or subject (it has no cards), or nil.
    var exportReason: (ExportTarget) -> String? = { _ in nil }
    /// Whether dropping an item on a target would work, and the drop itself.
    var verdict: (LibraryItem, DropTarget) -> LibraryMove.Verdict = { _, _ in .refused("") }
    var onDrop: (LibraryItem, DropTarget) -> Void = { _, _ in }
    /// The "Move to…" places for an item, and choosing one (nil is no subject, or the top level).
    var destinations: (LibraryItem) -> LibraryMove.Destinations = { _ in .none }
    var onMoveItem: (LibraryItem, Subject.ID?) -> Void = { _, _ in }

    /// The row being dragged, and the target it is held over.
    @State private var dragging: LibraryItem?
    @State private var hovered: DropTarget?

    private func dropTarget(_ target: DropTarget) -> LibraryDropTargetModifier {
        LibraryDropTargetModifier(
            target: target, dragging: dragging, hovered: hovered, verdict: verdict,
            onHover: { hovered = $0 },
            onDrop: { item, target in
                dragging = nil
                onDrop(item, target)
            },
            currentDrag: { dragging }
        )
    }

    private func dragProvider(_ item: LibraryItem) -> NSItemProvider {
        dragging = item
        return NSItemProvider(object: item.payload as NSString)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SearchField(
                text: $query,
                prompt: "Search cards",
                isFocused: isSearchFocused,
                onSubmit: { if let first = results.first { onSelectResult(first) } }
            )
            if isSearching {
                SearchResultsList(results: results, query: query, highlightedCardID: highlightedCardID, onSelect: onSelectResult)
            } else {
                library
            }
            if let reviewSelectionTitle {
                HStack(spacing: 6) {
                    Button(action: onReviewSelection) {
                        Label(reviewSelectionTitle, systemImage: "timer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.capsulePrimary)
                    .accessibilityHint("Opens the Review sprint with these ticked")
                    Button(action: onClearPicked) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .accessibilityLabel("Clear the chosen rows")
                }
            }
            NewMenuButton(items: newMenuItems, onChoose: onNew)
            NotchSettingsFooter(decks: decks, subjects: subjects)
        }
        // Leaves room for the traffic lights, which sit over the hidden title bar.
        .padding(.top, 38)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onSelectComposer) { CreateWithAIRow(isSelected: isComposerSelected, badge: composerBadge) }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let header):
                            Text(header.rawValue)
                                .font(Theme.Typography.sectionLabel)
                                .foregroundStyle(Theme.TextColor.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .modifier(dropTarget(header == .subjects ? .subjectsHeading : .decksHeading))
                                .padding(.top, header == .decks && rows.count > 1 ? 4 : 0)
                                .accessibilityAddTraits(.isHeader)
                        case .subject(let subject):
                            SidebarSubjectRow(
                                row: subject, onSelect: { onSelectSubject(subject.id) }, onToggle: { onToggleSubject(subject.id) }
                            )
                            .modifier(dropTarget(.subject(subject.id)))
                            .onDrag { dragProvider(.subject(subject.id)) }
                            .contextMenu {
                                Button("Rename") { onRenameSubject(subject.id) }
                                Picker("Color", selection: Binding(get: { subject.color }, set: { onSetSubjectColor(subject.id, $0) })) {
                                    ForEach(DeckColor.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                }
                                MoveToMenu(destinations: destinations(.subject(subject.id))) { onMoveItem(.subject(subject.id), $0) }
                                Button("Import…") { onImportSubject(subject.id) }
                                Button("Export…") { onExportSubject(subject.id) }
                                    .disabled(exportReason(.subject(subject.id)) != nil)
                                Divider()
                                Button("Delete…", role: .destructive) { onDeleteSubject(subject.id) }
                            }
                        case .deck(let deck):
                            Button { onSelectDeck(deck.id) } label: { SidebarDeckRow(row: deck) }
                                .buttonStyle(.plain)
                                .onDrag { dragProvider(.deck(deck.id)) }
                                .contextMenu {
                                    Button("Rename") { onRenameDeck(deck.id) }
                                    Picker("Color", selection: Binding(get: { deck.color }, set: { onSetDeckColor(deck.id, $0) })) {
                                        ForEach(DeckColor.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                    }
                                    MoveToMenu(destinations: destinations(.deck(deck.id))) { onMoveItem(.deck(deck.id), $0) }
                                    Button("Export…") { onExportDeck(deck.id) }
                                        .disabled(exportReason(.deck(deck.id)) != nil)
                                    Divider()
                                    Button("Delete…", role: .destructive) { onDeleteDeck(deck.id) }
                                }
                        }
                    }
                    if !hasLibrary {
                        Text("No decks yet")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(Theme.TextColor.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
            // Up and Down move through the visible rows; Right and Left open and close a subject.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: onMove(-1)
                case .down: onMove(1)
                case .right: onExpand(true)
                case .left: onExpand(false)
                @unknown default: break
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Cards matching the search, each with the deck it belongs to.
struct SearchResultsList: View {
    var results: [CardSearchResult]
    var query: String
    var highlightedCardID: Card.ID?
    var onSelect: (CardSearchResult) -> Void

    @Environment(\.accentChoice) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(results.isEmpty ? "No matches" : results.count == 1 ? "1 result" : "\(results.count) results")
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.TextColor.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { result in
                        let isSelected = result.id == highlightedCardID
                        Button { onSelect(result) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                DeckIcon(color: result.deckColor, size: 22, isOnAccent: isSelected)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.card.front.isEmpty ? "Untitled card" : result.card.front)
                                        .font(Theme.Typography.rowTitle.weight(.medium))
                                        .foregroundStyle(isSelected ? Theme.TextColor.onAccent : Theme.TextColor.primary)
                                    Text(result.card.back)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(isSelected ? Theme.TextColor.onAccent : Theme.TextColor.secondary)
                                    Text(result.deckPath ?? result.deckName)
                                        .font(Theme.Typography.sectionLabel)
                                        .foregroundStyle(isSelected ? Theme.TextColor.onAccent : accent.light)
                                }
                                .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.fill)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(result.card.front), \(result.card.back), in \(result.deckPath ?? result.deckName)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct DeckContentView: View {
    var deck: Deck?
    /// The subjects the deck is inside, outermost first; the breadcrumb above its title.
    var breadcrumb: [Subject] = []
    var onOpenSubject: (Subject.ID) -> Void = { _ in }
    @Binding var isRenaming: Bool
    @Binding var cardFocusRequest: Card.ID?
    var highlightedCardID: Card.ID?
    var onRename: (String) -> Void
    var onSetColor: (DeckColor) -> Void
    var onNewDeck: () -> Void
    var onAddCard: () -> Void
    /// Wired up by the import tickets; until then the buttons are disabled.
    var onImportCSV: (() -> Void)?
    var onPasteCards: (() -> Void)?
    /// Opens the Export sheet for this deck.
    var onExport: (() -> Void)?
    var exportReason: String?
    /// Opens Learn mode for this deck.
    var onLearn: (() -> Void)?
    /// Opens the Review sprint setup with this deck ticked.
    var onReview: (() -> Void)?
    /// Opens Create with AI to add cards to this deck.
    var onGenerate: (() -> Void)?
    var generateAvailability: DeckGenerateAvailability = .needsProvider

    @EnvironmentObject private var playback: PlaybackStore
    @EnvironmentObject private var study: StudyStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var isPickingColor = false

    var body: some View {
        if let deck {
            VStack(alignment: .leading, spacing: 22) {
                header(for: deck)
                HStack(alignment: .top, spacing: 24) {
                    CardEditor(
                        deck: deck,
                        focusRequest: $cardFocusRequest,
                        highlightedCardID: highlightedCardID,
                        onAddCard: onAddCard,
                        onPasteCards: onPasteCards,
                        onImportCSV: onImportCSV
                    )
                    // 300 leaves the 280 pt panel room beside it in a window at its minimum width.
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    nowShowing(for: deck)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 38)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        } else {
            VStack(spacing: 14) {
                Text("No decks yet")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.TextColor.secondary)
                Button("New Deck", action: onNewDeck)
                    .buttonStyle(.capsulePrimary)
            }
        }
    }

    /// The panel with grading under the card. In a short window the card gets shorter, and if even that
    /// isn't enough the panel scrolls rather than clipping.
    private func nowShowing(for deck: Deck) -> some View {
        GeometryReader { geometry in
            let panel = NowShowingPanel(
                deck: deck,
                state: playback.state(for: deck.id),
                // Flipping counts as studying, so the count line is looked at again right away.
                onFlip: {
                    playback.flip(deck)
                    study.refresh()
                },
                onSkip: { playback.skip(deck) },
                onGrade: {
                    playback.grade($0, deck)
                    study.refresh()
                },
                studySummary: { study.summary(at: $0, goal: settings.dailyGoal) },
                cardHeight: NowShowingPanel.cardHeight(available: geometry.size.height)
            )
            ViewThatFits(in: .vertical) {
                panel
                ScrollView(.vertical, showsIndicators: false) { panel }
            }
        }
        .frame(width: NowShowingPanel.side)
    }

    private func header(for deck: Deck) -> some View {
        // When the window is narrow the Appearance button moves into the ⋯ menu first, and then the
        // toolbar drops below the title.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                titleBlock(for: deck)
                Spacer(minLength: 16)
                toolbar(appearanceInMenu: false)
            }
            HStack(alignment: .bottom, spacing: 16) {
                titleBlock(for: deck)
                Spacer(minLength: 16)
                toolbar(appearanceInMenu: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock(for: deck)
                toolbar(appearanceInMenu: true)
            }
        }
    }

    private func titleBlock(for deck: Deck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !breadcrumb.isEmpty {
                SubjectBreadcrumb(path: breadcrumb, current: nil, onOpen: onOpenSubject)
            }
            HStack(spacing: 12) {
                Button { isPickingColor = true } label: { DeckIcon(color: deck.color, size: 30) }
                    .buttonStyle(.plain)
                    .help("Change deck color")
                    .accessibilityLabel("Deck color, \(deck.color.displayName)")
                    .popover(isPresented: $isPickingColor, arrowEdge: .bottom) {
                        DeckColorPicker(selection: deck.color) { color in
                            onSetColor(color)
                            isPickingColor = false
                        }
                    }
                EditableTitle(text: deck.name, isEditing: $isRenaming, onCommit: onRename)
            }
            // Widget and notch counts are placeholders until widget deck selection and the
            // notch settings exist.
            // Due changes with the clock, not with an edit, so it is looked at again every minute.
            TimelineView(.everyMinute) { context in
                Text(DeckSummary.subtitle(
                    cardCount: deck.cards.count, widgetCount: 0, showsInNotch: true,
                    dueCount: playback.state(for: deck.id).dueCount(in: deck, at: context.date)
                ))
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(Theme.TextColor.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func toolbar(appearanceInMenu: Bool) -> some View {
        DeckToolbar(
            onAddCard: onAddCard,
            onImportCSV: onImportCSV,
            onPasteCards: onPasteCards,
            onExport: onExport,
            exportReason: exportReason,
            onGenerate: onGenerate,
            generateAvailability: generateAvailability,
            onLearn: onLearn,
            learnNeedsCards: !(deck.map(LearnSession.canStart) ?? false),
            onReview: onReview,
            reviewMinutes: settings.reviewMinutes,
            appearance: $settings.appearance,
            appearanceInMenu: appearanceInMenu
        )
    }
}

/// Learn and Review next to one Add menu, so the whole toolbar still fits beside the title at the
/// window's minimum width. Learn and Review stay disabled until their screens exist.
struct DeckToolbar: View {
    var onAddCard: () -> Void
    var onImportCSV: (() -> Void)?
    var onPasteCards: (() -> Void)?
    /// Export…, in the ⋯ menu; nil leaves the menu out.
    var onExport: (() -> Void)?
    /// Why Export… is off (the deck has no cards), or nil.
    var exportReason: String?
    var onGenerate: (() -> Void)?
    var generateAvailability: DeckGenerateAvailability = .needsProvider
    /// Learn mode; nil leaves the button disabled.
    var onLearn: (() -> Void)?
    /// An empty deck has nothing to learn: the button says so instead of opening.
    var learnNeedsCards = false
    /// Opens the Review sprint's setup; nil leaves the button disabled.
    var onReview: (() -> Void)?
    /// The length the next sprint starts with, shown on the button ("Review 10 min").
    var reviewMinutes: Int?
    /// The appearance setting: a round button after Review, or nil for none.
    var appearance: Binding<AppearanceChoice>?
    /// Too narrow for the button: Appearance ▸ goes in the ⋯ menu instead.
    var appearanceInMenu = false

    @State private var isShowingLearnNotice = false

    var body: some View {
        HStack(spacing: 8) {
            Button("Learn") {
                if learnNeedsCards { isShowingLearnNotice = true } else { onLearn?() }
            }
                .buttonStyle(.capsuleSecondary)
                .disabled(onLearn == nil)
                .opacity(onLearn == nil ? 0.5 : 1)
                .help(onLearn == nil ? "Coming soon" : "Go through the deck one card at a time")
                .accessibilityHint("Goes through the deck one card at a time, without grades")
                .popover(isPresented: $isShowingLearnNotice, arrowEdge: .bottom) {
                    Text("Add a card to start learning")
                        .font(Theme.Typography.caption)
                        .padding(14)
                }
            Button { onReview?() } label: {
                Label(reviewMinutes.map { "Review \($0) min" } ?? "Review", systemImage: "timer")
            }
                .buttonStyle(.capsulePrimary)
                .disabled(onReview == nil)
                .opacity(onReview == nil ? 0.5 : 1)
                .help(onReview == nil ? "Coming soon" : "Review the cards that are due against the clock")
                .accessibilityHint("Opens the Review sprint setup")
            if let appearance, !appearanceInMenu { AppearanceButton(selection: appearance) }
            addMenu
            if onExport != nil || (appearance != nil && appearanceInMenu) { moreMenu }
        }
        .fixedSize()
    }

    /// What the ⋯ menu holds: Export…, and Appearance ▸ when the button doesn't fit.
    static func moreMenuTitles(hasExport: Bool, appearanceInMenu: Bool) -> [String] {
        (hasExport ? ["Export…"] : []) + (appearanceInMenu ? ["Appearance"] : [])
    }

    private var moreMenu: some View {
        Menu {
            if let onExport {
                Button("Export…", action: onExport)
                    .disabled(exportReason != nil)
            }
            if let appearance, appearanceInMenu {
                Menu("Appearance") { AppearanceMenuItems(selection: appearance) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
        }
        .menuStyle(.button)
        .buttonStyle(.capsuleSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(exportReason ?? "More")
        .accessibilityLabel("More")
        .accessibilityHint(exportReason ?? "Export this deck")
    }

    private var addMenu: some View {
        Menu {
            Button("Add Card", action: onAddCard)
            Divider()
            Button("Paste Cards") { onPasteCards?() }
                .disabled(onPasteCards == nil)
            Button("Import…") { onImportCSV?() }
                .disabled(onImportCSV == nil)
            Button { onGenerate?() } label: { Label("Generate…", systemImage: "sparkles") }
                .disabled(onGenerate == nil || generateAvailability != .available)
                .help(generateAvailability.help)
        } label: {
            HStack(spacing: 6) {
                Text("Add")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.capsuleSecondary)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Add")
        .accessibilityHint("Add a card, paste cards, import a CSV or Anki package, or make cards with AI")
    }
}

#if DEBUG
enum PreviewData {
    static let decks = [
        Deck(name: "Everyday Spanish", color: .accent, cards: [
            Card(front: "la mariposa", back: "the butterfly"),
            Card(front: "el desayuno", back: "breakfast"),
            Card(front: "tener prisa", back: "to be in a hurry"),
            Card(front: "la sobremesa", back: "lingering at the table after a meal"),
        ]),
        Deck(name: "Biology 101", color: .green, cards: [Card(front: "mitosis", back: "cell division")]),
        Deck(name: "Swift Interview", color: .purple),
        Deck(name: "World Capitals", color: .orange),
    ]

    @MainActor
    static func store(decks: [Deck] = decks) -> DeckStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        try? DeckStorage(directory: dir).save(decks)
        return DeckStore(storage: DeckStorage(directory: dir), onSaved: {})
    }
}

extension PreviewData {
    @MainActor
    static func settings() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        return SettingsStore(storage: SettingsStorage(directory: dir), onSaved: {})
    }

    /// A composer on throwaway stores and an in-memory Keychain, for previews and tests.
    @MainActor
    static func composer(settings: SettingsStore? = nil) -> ComposerModel {
        let settings = settings ?? Self.settings()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        let ai = AIAccountStore(secrets: InMemorySecretStore(), cacheStorage: AIModelCacheStorage(directory: dir), settings: settings)
        return ComposerModel(settings: settings, ai: ai)
    }

    @MainActor
    static func study() -> StudyStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        return StudyStore(storage: StudyStorage(directory: dir))
    }

    @MainActor
    static func studyClock() -> StudyClockGate {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        return StudyClockGate(sessions: SessionStore(storage: SessionStorage(directory: dir), studyStorage: StudyStorage(directory: dir)))
    }

    @MainActor
    static func runHistory() -> RunHistoryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        return RunHistoryStore(storage: RunHistoryStorage(directory: dir))
    }

    @MainActor
    static func playback() -> PlaybackStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainPreview-\(UUID().uuidString)")
        return PlaybackStore(storage: PlaybackStorage(directory: dir), onSaved: {})
    }
}

#Preview("Main window") {
    MainWindowView()
        .environmentObject(PreviewData.store())
        .environmentObject(PreviewData.playback())
        .environmentObject(PreviewData.study())
        .environmentObject(PreviewData.runHistory())
        .environmentObject(PreviewData.studyClock())
        .environmentObject(PreviewData.settings())
        .environmentObject(PreviewData.composer())
}

#Preview("Main window, empty") {
    MainWindowView()
        .environmentObject(PreviewData.store(decks: []))
        .environmentObject(PreviewData.playback())
        .environmentObject(PreviewData.study())
        .environmentObject(PreviewData.runHistory())
        .environmentObject(PreviewData.studyClock())
        .environmentObject(PreviewData.settings())
        .environmentObject(PreviewData.composer())
}
#endif

/// A file opened with FishBrain from Finder, Mail or AirDrop shows the Import sheet, and the File menu's
/// commands follow what is open and whether there is anything to export.
private struct MainWindowEntryPoints: ViewModifier {
    var router: DeepLinkRouter
    var exportAvailable: Bool
    var selectedSubjectID: Subject.ID?
    var onImportURL: (URL) -> Void
    var onCommandsChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(router.$pendingImportURL) { url in
                guard let url else { return }
                router.pendingImportURL = nil
                onImportURL(url)
            }
            .onChange(of: exportAvailable) { onCommandsChanged() }
            .onChange(of: selectedSubjectID) { onCommandsChanged() }
    }
}
