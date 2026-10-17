import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Pictures on cards (FLAS-42).
enum PictureFixtures {
    /// A solid picture (or one half transparent) as a bitmap.
    static func cgImage(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
        )!
        if alpha { context.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        context.setFillColor(red: 0.1, green: 0.6, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: alpha ? width / 2 : width, height: height))
        return context.makeImage()!
    }

    /// The picture as file data of the given type (PNG, JPEG, TIFF, GIF, BMP...).
    static func data(width: Int, height: Int, alpha: Bool = false, type: UTType = .png, orientation: Int? = nil) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, cgImage(width: width, height: height, alpha: alpha), properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "could not make the test picture")
        return output as Data
    }

    /// A JPEG whose pixels are `width` x `height` but which the camera says to turn a quarter.
    static func rotatedJPEG(width: Int, height: Int) -> Data {
        data(width: width, height: height, type: .jpeg, orientation: 6)
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func hasAlpha(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FishBrainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Makes a file look like it was written a while ago, so the cleanup's grace period doesn't protect it.
    static func age(_ url: URL, by seconds: TimeInterval = 3600) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }
}

final class CardImageStoreTests: XCTestCase {
    private var root: URL!
    private var store: CardImageStore!

    override func setUpWithError() throws {
        root = try PictureFixtures.tempDirectory()
        store = CardImageStore.beside(root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testABigPictureIsScaledDownToTheLimitAndGetsASmallCopy() throws {
        let image = try store.add(data: PictureFixtures.data(width: 3200, height: 2000))
        let full = try XCTUnwrap(PictureFixtures.pixelSize(store.url(for: image)))
        let small = try XCTUnwrap(PictureFixtures.pixelSize(store.url(for: image, thumbnail: true)))
        XCTAssertEqual(max(full.width, full.height), CardImageStore.maxLongEdge)
        XCTAssertEqual(max(small.width, small.height), CardImageStore.thumbnailLongEdge)
        XCTAssertEqual(Double(full.width) / Double(full.height), 1.6, accuracy: 0.01, "same shape")
        XCTAssertTrue(image.fileName.hasSuffix(".jpg"), "no transparency, so a JPEG")
    }

    func testASmallPictureIsNotBlownUp() throws {
        let image = try store.add(data: PictureFixtures.data(width: 300, height: 200))
        XCTAssertEqual(PictureFixtures.pixelSize(store.url(for: image))?.width, 300)
        XCTAssertEqual(PictureFixtures.pixelSize(store.url(for: image, thumbnail: true))?.width, 300)
    }

    func testAPictureWithTransparencyStaysAPNG() throws {
        let image = try store.add(data: PictureFixtures.data(width: 400, height: 400, alpha: true))
        XCTAssertTrue(image.fileName.hasSuffix(".png"))
        XCTAssertTrue(PictureFixtures.hasAlpha(store.url(for: image)))
        XCTAssertTrue(image.thumbnailFileName.hasSuffix("-thumb.png"))
    }

    func testTheFormatsPeopleHaveAreAccepted() throws {
        for type in [UTType.jpeg, .tiff, .gif, .png, .bmp] {
            XCTAssertNoThrow(try store.add(data: PictureFixtures.data(width: 200, height: 120, type: type)), "\(type)")
        }
    }

    func testTheCamerasRotationIsAppliedSoItIsntSidewaysOnTheCard() throws {
        let image = try store.add(data: PictureFixtures.rotatedJPEG(width: 300, height: 100))
        let size = try XCTUnwrap(PictureFixtures.pixelSize(store.url(for: image)))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 300, "turned a quarter, as the camera meant")
    }

    func testSomethingThatIsNotAPictureIsTurnedDownAndLeavesNothingBehind() {
        XCTAssertThrowsError(try store.add(data: Data("not a picture".utf8)))
        XCTAssertThrowsError(try store.add(data: Data()))
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path))?.isEmpty ?? true)
    }

    func testAPictureCanBeReadFromAFile() throws {
        let file = root.appendingPathComponent("photo.png")
        try PictureFixtures.data(width: 500, height: 300).write(to: file)
        let image = try store.add(contentsOf: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: image).path))
        XCTAssertNotNil(store.nsImage(for: image, thumbnail: true))
        XCTAssertNotNil(store.nsImage(for: image, thumbnail: false))
    }

    func testTheSmallCopysNameFollowsTheMainOnes() {
        XCTAssertEqual(CardImage(fileName: "ABC.jpg").thumbnailFileName, "ABC-thumb.jpg")
        XCTAssertEqual(CardImage(fileName: "ABC.png").fileNames, ["ABC.png", "ABC-thumb.png"])
    }

    // MARK: Cleanup

    func testCleanupRemovesWhatNoCardUsesAndKeepsWhatItDoes() throws {
        let kept = try store.add(data: PictureFixtures.data(width: 100, height: 100))
        let orphan = try store.add(data: PictureFixtures.data(width: 100, height: 100))
        for image in [kept, orphan] { for name in image.fileNames { try PictureFixtures.age(store.directory.appendingPathComponent(name)) } }
        XCTAssertEqual(store.sweep(keeping: Set(kept.fileNames)), 2, "the orphan's two files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: kept).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: kept, thumbnail: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: orphan).path))
    }

    func testAPictureJustAddedIsNeverSweptBeforeItsCardIsSaved() throws {
        let fresh = try store.add(data: PictureFixtures.data(width: 100, height: 100))
        XCTAssertEqual(store.sweep(keeping: []), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: fresh).path))
    }

    func testCleanupOfAFolderThatDoesntExistIsHarmless() {
        XCTAssertEqual(CardImageStore.beside(root.appendingPathComponent("nope")).sweep(keeping: []), 0)
    }
}

final class CardImageModelTests: XCTestCase {
    func testAnOlderCardWithoutPicturesStillLoads() throws {
        let id = UUID()
        let card = try JSONDecoder().decode(Card.self, from: Data(#"{"id":"\#(id)","front":"a","back":"b"}"#.utf8))
        XCTAssertNil(card.frontImage)
        XCTAssertNil(card.backImage)
        XCTAssertTrue(card.imageFileNames.isEmpty)
    }

    func testAPictureRoundTripsWithItsDescription() throws {
        var card = Card(front: "a", back: "b")
        card.frontImage = CardImage(fileName: "X.jpg", altText: "a red fox")
        card.setImage(CardImage(fileName: "Y.png", altText: nil), on: .back)
        let decoded = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(decoded, card)
        XCTAssertEqual(decoded.image(on: .front)?.altText, "a red fox")
        XCTAssertEqual(decoded.imageFileNames, ["X.jpg", "X-thumb.jpg", "Y.png", "Y-thumb.png"])
    }

    func testACardWithoutPicturesWritesNoPictureKeys() throws {
        let json = String(decoding: try JSONEncoder().encode(Card(front: "a", back: "b")), as: UTF8.self)
        XCTAssertFalse(json.contains("Image"))
    }

    func testTheLibraryListsEveryFileItUses() {
        let a = Card(front: "a", back: "b", frontImage: CardImage(fileName: "1.jpg"), backImage: CardImage(fileName: "2.jpg"))
        let b = Card(front: "c", back: "d", backImage: CardImage(fileName: "3.png"))
        let decks = [Deck(name: "One", color: .green, cards: [a]), Deck(name: "Two", color: .purple, cards: [b])]
        XCTAssertEqual(decks.imageFileNames, ["1.jpg", "1-thumb.jpg", "2.jpg", "2-thumb.jpg", "3.png", "3-thumb.png"])
    }
}

final class PictureStorageVersionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testTheVersionIsThreeSoAnOlderBuildRefusesToDropPicturesAndSubjects() throws {
        XCTAssertEqual(DeckStorage.currentVersion, 3)
        let storage = DeckStorage(directory: directory)
        try storage.save([Deck(name: "X", color: .green)])
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.fileURL)) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 3)
    }

    func testAVersionOneFileLoadsUnchanged() throws {
        let id = UUID()
        let storage = DeckStorage(directory: directory)
        let json = #"{"version":1,"decks":[{"id":"\#(id)","name":"Old","color":"green","cards":[{"id":"\#(UUID())","front":"a","back":"b"}]}]}"#
        try Data(json.utf8).write(to: storage.fileURL)
        let decks = storage.load()
        XCTAssertEqual(decks.first?.name, "Old")
        XCTAssertEqual(decks.first?.cards.first?.front, "a")
        XCTAssertNil(decks.first?.cards.first?.frontImage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.fileURL.path), "not moved aside")
    }

    func testPicturesSurviveASaveAndLoad() throws {
        let storage = DeckStorage(directory: directory)
        let card = Card(front: "a", back: "b", frontImage: CardImage(fileName: "X.jpg", altText: "a fox"))
        try storage.save([Deck(name: "X", color: .green, cards: [card])])
        XCTAssertEqual(storage.load().first?.cards.first?.frontImage, card.frontImage)
    }

    func testANewerVersionIsStillRefused() throws {
        let storage = DeckStorage(directory: directory)
        try Data(#"{"version":4,"subjects":[],"decks":[]}"#.utf8).write(to: storage.fileURL)
        XCTAssertEqual(storage.load(), [])
    }
}

@MainActor
final class DeckStorePictureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try PictureFixtures.tempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeStore(decks: [Deck] = []) throws -> DeckStore {
        if !decks.isEmpty { try DeckStorage(directory: root).save(decks) }
        return DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(1), onSaved: {})
    }

    private func settle(_ store: DeckStore) async {
        await store.settled()
    }

    /// Adds a picture file and ages it so the cleanup's grace period no longer protects it.
    private func attach(_ store: DeckStore, side: CardSide = .front, to card: Card, in deck: Deck) async throws -> CardImage {
        try await store.addImage(data: PictureFixtures.data(width: 600, height: 400), on: side, for: card.id, in: deck.id)
        let image = try XCTUnwrap(store.card(card.id, in: deck.id)?.image(on: side))
        // Let the save and cleanup this edit triggers (and any left over from earlier) finish before the
        // files are aged: a cleanup that started before the card held this picture must not see it as old.
        await settle(store)
        for name in image.fileNames { try PictureFixtures.age(store.imageStore.directory.appendingPathComponent(name)) }
        return image
    }

    private func fileExists(_ image: CardImage, in store: DeckStore) -> Bool {
        FileManager.default.fileExists(atPath: store.imageStore.url(for: image).path)
            || FileManager.default.fileExists(atPath: store.imageStore.url(for: image, thumbnail: true).path)
    }

    func testAddingAPictureAttachesItToThatSideOfThatCard() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b"), Card(front: "c", back: "d")])
        let store = try makeStore(decks: [deck])
        try await store.addImage(data: PictureFixtures.data(width: 800, height: 500), on: .back, for: deck.cards[1].id, in: deck.id)
        XCTAssertNil(store.card(deck.cards[1].id, in: deck.id)?.frontImage)
        XCTAssertNotNil(store.card(deck.cards[1].id, in: deck.id)?.backImage)
        XCTAssertNil(store.card(deck.cards[0].id, in: deck.id)?.backImage)
    }

    func testReplacingAPictureRemovesTheOldFiles() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b")])
        let store = try makeStore(decks: [deck])
        let old = try await attach(store, to: deck.cards[0], in: deck)
        await settle(store)
        let new = try await attach(store, to: deck.cards[0], in: deck)
        await settle(store)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(fileExists(old, in: store), "the replaced picture is gone")
        XCTAssertTrue(fileExists(new, in: store))
    }

    func testRemovingAPictureDeletesItsFiles() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b")])
        let store = try makeStore(decks: [deck])
        let image = try await attach(store, to: deck.cards[0], in: deck)
        await settle(store)
        store.setImage(nil, on: .front, for: deck.cards[0].id, in: deck.id)
        await settle(store)
        XCTAssertFalse(fileExists(image, in: store))
    }

    func testDeletingACardDeletesItsPictures() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b"), Card(front: "c", back: "d")])
        let store = try makeStore(decks: [deck])
        let doomed = try await attach(store, side: .front, to: deck.cards[0], in: deck)
        let kept = try await attach(store, side: .back, to: deck.cards[1], in: deck)
        await settle(store)
        store.deleteCards([deck.cards[0].id], in: deck.id)
        await settle(store)
        XCTAssertFalse(fileExists(doomed, in: store))
        XCTAssertTrue(fileExists(kept, in: store), "the other card's picture stays")
    }

    func testDeletingADeckDeletesItsPictures() async throws {
        let one = Deck(name: "One", color: .green, cards: [Card(front: "a", back: "b")])
        let two = Deck(name: "Two", color: .purple, cards: [Card(front: "c", back: "d")])
        let store = try makeStore(decks: [one, two])
        let doomed = try await attach(store, to: one.cards[0], in: one)
        let kept = try await attach(store, to: two.cards[0], in: two)
        await settle(store)
        store.deleteDeck(one.id)
        await settle(store)
        XCTAssertFalse(fileExists(doomed, in: store))
        XCTAssertTrue(fileExists(kept, in: store))
    }

    func testADeletedDeckKeepsItsPicturesWhileUndoCanBringItBack() async throws {
        let one = Deck(name: "One", color: .green, cards: [Card(front: "a", back: "b")])
        let two = Deck(name: "Two", color: .purple, cards: [Card(front: "c", back: "d")])
        let store = try makeStore(decks: [one, two])
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let picture = try await attach(store, to: one.cards[0], in: one)
        await settle(store)

        undo.beginUndoGrouping()
        store.deleteDeck(one.id)
        undo.endUndoGrouping()
        await settle(store)
        XCTAssertTrue(fileExists(picture, in: store), "kept: the delete can still be undone")

        undo.undo()
        await settle(store)
        XCTAssertEqual(store.decks.map(\.id), [one.id, two.id])
        XCTAssertTrue(fileExists(picture, in: store))
        XCTAssertEqual(store.decks.first?.cards.first?.frontImage, picture, "and the card still points at it")
    }

    func testPicturesLeftBehindAreCleanedUpAtLaunch() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b")])
        let first = try makeStore(decks: [deck])
        let orphan = try first.imageStore.add(data: PictureFixtures.data(width: 200, height: 200))
        for name in orphan.fileNames { try PictureFixtures.age(first.imageStore.directory.appendingPathComponent(name)) }
        let relaunched = try makeStore()
        _ = await relaunched.pendingSweep?.value
        XCTAssertFalse(fileExists(orphan, in: relaunched))
    }

    func testAnEmptyLibraryNeverTriggersALaunchCleanup() async throws {
        // An unreadable decks.json comes back as no decks; that mustn't look like "no card uses any picture".
        let store = CardImageStore.beside(root)
        let image = try store.add(data: PictureFixtures.data(width: 200, height: 200))
        for name in image.fileNames { try PictureFixtures.age(store.directory.appendingPathComponent(name)) }
        try Data("garbage".utf8).write(to: DeckStorage(directory: root).fileURL)
        let relaunched = DeckStore(storage: DeckStorage(directory: root), debounce: .milliseconds(1), onSaved: {})
        XCTAssertNil(relaunched.pendingSweep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: image).path))
    }

    func testAPictureForACardDeletedMeanwhileIsDroppedQuietly() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b")])
        let store = try makeStore(decks: [deck])
        let gone = deck.cards[0].id
        store.deleteCards([gone], in: deck.id)
        try await store.addImage(data: PictureFixtures.data(width: 200, height: 200), on: .front, for: gone, in: deck.id)
        XCTAssertNil(store.card(gone, in: deck.id))
    }

    func testAFileThatIsNotAPictureThrowsAndChangesNothing() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b")])
        let store = try makeStore(decks: [deck])
        let file = root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        do {
            try await store.addImage(contentsOf: file, on: .front, for: deck.cards[0].id, in: deck.id)
            XCTFail("should throw")
        } catch {}
        XCTAssertNil(store.card(deck.cards[0].id, in: deck.id)?.frontImage)
    }

    func testTheDescriptionIsTrimmedAndBlankGoesBackToTheCardsText() async throws {
        let deck = Deck(name: "D", color: .green, cards: [Card(front: "a", back: "b")])
        let store = try makeStore(decks: [deck])
        try await store.addImage(data: PictureFixtures.data(width: 200, height: 200), on: .front, for: deck.cards[0].id, in: deck.id)
        store.setAltText("  a red fox  ", on: .front, for: deck.cards[0].id, in: deck.id)
        XCTAssertEqual(store.card(deck.cards[0].id, in: deck.id)?.frontImage?.altText, "a red fox")
        store.setAltText("   ", on: .front, for: deck.cards[0].id, in: deck.id)
        XCTAssertNil(store.card(deck.cards[0].id, in: deck.id)?.frontImage?.altText)
        store.setAltText("ignored", on: .back, for: deck.cards[0].id, in: deck.id) // no picture there
        XCTAssertNil(store.card(deck.cards[0].id, in: deck.id)?.backImage)
    }
}

final class PictureSearchAndSpeechTests: XCTestCase {
    func testSearchFindsAPicturesDescription() {
        let card = Card(front: "la zorra", back: "", frontImage: CardImage(fileName: "x.jpg", altText: "a red fox in snow"))
        let decks = [Deck(name: "Animals", color: .green, cards: [card, Card(front: "el gato", back: "the cat")])]
        XCTAssertEqual(CardSearch.search("fox", in: decks).map(\.card.id), [card.id])
        XCTAssertEqual(CardSearch.search("SNOW", in: decks).count, 1)
        XCTAssertTrue(CardSearch.search("whale", in: decks).isEmpty)
    }

    func testVoiceOverReadsTheDescriptionOrFallsBackToTheText() {
        let described = CardImage(fileName: "x.jpg", altText: "a red fox")
        let plain = CardImage(fileName: "x.jpg")
        XCTAssertEqual(CardFace.accessibilityText("la zorra", isBack: false, image: described), "la zorra, picture: a red fox")
        XCTAssertEqual(CardFace.accessibilityText("la zorra", isBack: false, image: plain), "la zorra", "the card's text stands in")
        XCTAssertEqual(CardFace.accessibilityText("", isBack: false, image: plain), "Picture")
        XCTAssertEqual(CardFace.accessibilityText("", isBack: false, image: described), "Picture, a red fox")
        XCTAssertEqual(CardFace.accessibilityText("the fox", isBack: true, image: described), "Answer, the fox, picture: a red fox")
        XCTAssertEqual(CardFace.accessibilityText("", isBack: true, image: plain), "Answer, Picture")
    }

    func testACardWithoutAPictureIsReadAsBefore() {
        XCTAssertEqual(CardFace.accessibilityText("hola", isBack: false), "hola")
        XCTAssertEqual(CardFace.accessibilityText("", isBack: false), "Blank card")
        XCTAssertEqual(CardFace.accessibilityText("", isBack: true), "Answer, blank")
    }

    func testOnlyPictureFilesAreAcceptedWhenDropped() {
        for name in ["a.png", "a.JPG", "a.jpeg", "a.heic", "a.gif", "a.tiff"] {
            XCTAssertTrue(PictureSource.isPicture(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        for name in ["a.pdf", "a.txt", "a.csv", "a", "a.mov"] {
            XCTAssertFalse(PictureSource.isPicture(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
    }
}

final class PicturePasteboardTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("FishBrainTests-\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        board.clearContents()
        return board
    }

    func testPictureDataOnTheClipboardIsRead() throws {
        let board = pasteboard()
        board.setData(PictureFixtures.data(width: 50, height: 50), forType: .png)
        guard case .data(let data)? = PicturePasteboard.read(from: board) else { return XCTFail("data") }
        XCTAssertFalse(data.isEmpty)
    }

    func testACopiedPictureFileIsReadAsAFile() throws {
        let directory = try PictureFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("p.png")
        try PictureFixtures.data(width: 50, height: 50).write(to: file)
        let board = pasteboard()
        board.writeObjects([file as NSURL])
        guard case .file(let url)? = PicturePasteboard.read(from: board) else { return XCTFail("file") }
        XCTAssertEqual(url.lastPathComponent, "p.png")
    }

    func testTextOnTheClipboardIsNotAPicture() {
        let board = pasteboard()
        board.setString("hello", forType: .string)
        XCTAssertNil(PicturePasteboard.read(from: board))
    }
}
