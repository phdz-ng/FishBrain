import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pictures on cards: the files in the `Images` folder next to `decks.json` (so the widget can read
/// them too), made from whatever the user adds. Each picture is stored twice, scaled down: a main copy
/// (long edge at most 1600 px) and a small one (400 px) for the widget and the notch, where memory is
/// tight.
struct CardImageStore: Sendable {
    static let maxLongEdge = 1600
    static let thumbnailLongEdge = 400
    static let jpegQuality = 0.85
    /// A file this young is never swept: the picture may have just been added, with the card that
    /// holds it still being saved.
    static let sweepGrace: TimeInterval = 60

    enum ImageError: Error {
        case unreadable
        case encodingFailed
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The library's own folder. Worked out once: card faces ask for it every time they are drawn.
    static let shared = CardImageStore(directory: AppGroup.storageDirectory().appendingPathComponent("Images", isDirectory: true))

    /// The folder for a library stored in `storageDirectory`.
    static func beside(_ storageDirectory: URL) -> CardImageStore {
        CardImageStore(directory: storageDirectory.appendingPathComponent("Images", isDirectory: true))
    }

    func url(for image: CardImage, thumbnail: Bool = false) -> URL {
        directory.appendingPathComponent(thumbnail ? image.thumbnailFileName : image.fileName)
    }

    // MARK: Adding

    /// Reads a picture from a file (PNG, JPEG, HEIC, GIF, TIFF, ...), including one the user picked or dropped
    /// in, which needs its sandbox access opened for the moment it is read.
    func add(contentsOf url: URL) throws -> CardImage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try add(data: Data(contentsOf: url))
    }

    /// Makes the stored copies from image data. The first frame of an animation is used, the camera's
    /// rotation is applied, and a picture with transparency stays a PNG while any other becomes a JPEG.
    func add(data: Data) throws -> CardImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw ImageError.unreadable }

        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let longEdge = max(width, height)
        guard let full = Self.scaled(source, maxPixel: min(longEdge, Self.maxLongEdge)),
              let small = Self.scaled(source, maxPixel: min(longEdge, Self.thumbnailLongEdge))
        else { throw ImageError.unreadable }

        let base = UUID().uuidString
        let image = CardImage(fileName: "\(base).\(hasAlpha ? "png" : "jpg")", altText: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(full, png: hasAlpha).write(to: url(for: image), options: .atomic)
        try Self.encode(small, png: hasAlpha).write(to: url(for: image, thumbnail: true), options: .atomic)
        return image
    }

    static func scaled(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    static func encode(_ image: CGImage, png: Bool) throws -> Data {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw ImageError.encodingFailed }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.encodingFailed }
        return data as Data
    }

    // MARK: Removing

    func remove(_ image: CardImage) {
        for name in image.fileNames { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
    }

    /// Deletes the files no card uses any more (a card or deck was deleted, or a picture replaced).
    /// Files younger than `sweepGrace` stay. Returns how many were removed.
    @discardableResult
    func sweep(keeping referenced: Set<String>, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for file in files where !referenced.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) < Self.sweepGrace { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Showing

    /// A picture ready to draw. Decoded once and kept, since a card face is redrawn often.
    func nsImage(for image: CardImage, thumbnail: Bool) -> NSImage? {
        Self.cache.image(at: url(for: image, thumbnail: thumbnail))
    }

    private static let cache = ImageCache()

    private final class ImageCache: @unchecked Sendable {
        private let cache = NSCache<NSURL, NSImage>()

        init() {
            cache.countLimit = 40
        }

        func image(at url: URL) -> NSImage? {
            if let cached = cache.object(forKey: url as NSURL) { return cached }
            guard let image = NSImage(contentsOf: url) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
    }
}

extension Collection where Element == Deck {
    /// Every image file the library points at.
    var imageFileNames: Set<String> {
        reduce(into: Set<String>()) { names, deck in
            for card in deck.cards { names.formUnion(card.imageFileNames) }
        }
    }
}

/// Where a picture for a card comes from.
enum PictureSource: Sendable {
    case file(URL)
    case data(Data)

    /// Whether a file looks like a picture, judged by its type, so a dropped PDF or text file is
    /// turned down before anything is read.
    static func isPicture(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

/// Reads a picture off the clipboard.
enum PicturePasteboard {
    private static let dataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// A picture file copied in Finder, or picture data copied from an app (a screenshot, a browser).
    /// Files come first: copying a file also puts its icon on the clipboard.
    static func read(from pasteboard: NSPasteboard = .general) -> PictureSource? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first(where: PictureSource.isPicture) {
            return .file(url)
        }
        for type in dataTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return .data(data) }
        }
        return nil
    }
}
