import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Why a file can't be used, in words a person can act on.
enum SourceError: Error, Equatable, Sendable {
    case passwordProtected(filename: String)
    case unreadable(filename: String)
    case unsupported(filename: String)
    case empty(filename: String)
    case badPageRange

    var message: String {
        switch self {
        case .passwordProtected(let name): "“\(name)” is password protected. Remove the password and add it again."
        case .unreadable(let name): "“\(name)” couldn't be read."
        case .unsupported(let name): "“\(name)” isn't a PDF, a picture or a text file FishBrain can use."
        case .empty(let name): "“\(name)” has nothing in it to make cards from."
        case .badPageRange: "That range of pages isn't in this PDF."
        }
    }
}

/// How much can be sent in one go.
enum SourceLimits {
    /// Anthropic takes 32 MB a request and OpenAI 50 MB, so stay under the smaller with room to spare.
    static let maxRequestBytes = 30 * 1024 * 1024
    /// Both providers read up to 600 pages of PDF in a request.
    static let maxPDFPages = 600
    /// Pictures are scaled down to this long edge before sending: enough to read text in, and under
    /// Anthropic's stricter limit for requests with many pictures.
    static let maxImageLongEdge = 2000
    /// A text file bigger than this is far more than a model reads usefully in one go.
    static let maxTextBytes = 8 * 1024 * 1024
    /// What the prompt itself adds.
    static let promptOverheadBytes = 64 * 1024
}

/// Why a set of sources can't be sent as it stands.
enum SizeProblem: Equatable, Sendable {
    /// `bytes` is what would be sent.
    case tooBig(bytes: Int)
    case tooManyPages(pages: Int)

    var message: String {
        switch self {
        case .tooBig(let bytes):
            let megabytes = Int((Double(bytes) / 1_048_576).rounded(.up))
            return "That's about \(megabytes) MB, more than can be sent at once (\(SourceLimits.maxRequestBytes / 1_048_576) MB). Use fewer files, or choose a range of pages."
        case .tooManyPages(let pages):
            return "That's \(pages) pages of PDF; at most \(SourceLimits.maxPDFPages) can be sent at once. Choose a range of pages, or fewer files."
        }
    }
}

extension GenerationRequest {
    /// Roughly what sending this would weigh: documents and pictures go out as base64 (a third bigger),
    /// text as it is, and the prompt adds a little.
    var estimatedPayloadBytes: Int {
        sources.reduce(SourceLimits.promptOverheadBytes + focus.utf8.count) { total, source in
            switch source {
            case .pdf(let pdf): total + pdf.data.count * 4 / 3
            case .image(let image): total + image.data.count * 4 / 3
            case .text(let text): total + text.text.utf8.count
            }
        } + existingFronts.reduce(0) { $0 + min($1.utf8.count, GenerationPrompt.maxExistingFrontLength) }
    }

    var totalPDFPages: Int {
        sources.reduce(0) { total, source in
            if case .pdf(let pdf) = source { total + pdf.pageCount } else { total }
        }
    }

    /// Whether this can be sent: not too heavy, not too many pages.
    var sizeProblem: SizeProblem? {
        if totalPDFPages > SourceLimits.maxPDFPages { return .tooManyPages(pages: totalPDFPages) }
        let bytes = estimatedPayloadBytes
        if bytes > SourceLimits.maxRequestBytes { return .tooBig(bytes: bytes) }
        return nil
    }
}

/// Turns what the person gave into something that can be sent.
enum GenerationInputs {
    // MARK: PDF

    /// Reads a PDF. A password protected or damaged one is turned down here, with a message, instead of
    /// failing at the provider.
    static func pdf(from data: Data, filename: String) throws -> PDFSource {
        guard let document = PDFDocument(data: data) else { throw SourceError.unreadable(filename: filename) }
        if document.isLocked { throw SourceError.passwordProtected(filename: filename) }
        guard document.pageCount > 0 else { throw SourceError.empty(filename: filename) }
        return PDFSource(data: data, filename: filename, pageCount: document.pageCount, firstPage: 1, originalPageCount: document.pageCount)
    }

    static func pdf(at url: URL) throws -> PDFSource {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw SourceError.unreadable(filename: url.lastPathComponent) }
        return try pdf(from: data, filename: url.lastPathComponent)
    }

    /// Just some pages of a PDF (1-based, inclusive), for when the whole thing is too big. Card page numbers
    /// still follow the original.
    static func excerpt(of source: PDFSource, pages: ClosedRange<Int>) throws -> PDFSource {
        let original = source.originalPageCount ?? source.pageCount
        guard source.firstPage == 1, source.pageCount == original else { throw SourceError.badPageRange }
        guard pages.lowerBound >= 1, pages.upperBound <= original, let document = PDFDocument(data: source.data) else {
            throw SourceError.badPageRange
        }
        let excerpt = PDFDocument()
        for (offset, page) in pages.enumerated() {
            guard let copy = document.page(at: page - 1)?.copy() as? PDFPage else { throw SourceError.badPageRange }
            excerpt.insert(copy, at: offset)
        }
        guard let data = excerpt.dataRepresentation() else { throw SourceError.unreadable(filename: source.filename) }
        return PDFSource(data: data, filename: source.filename, pageCount: pages.count, firstPage: pages.lowerBound, originalPageCount: original)
    }

    // MARK: Pictures

    /// Reads a picture (PNG, JPEG, HEIC, GIF's first frame, TIFF, WebP...) and scales it so its long edge is
    /// at most 2000 px. It goes out as a JPEG, or a PNG when it has transparency. Camera rotation is applied.
    static func image(from data: Data, filename: String) throws -> ImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw SourceError.unreadable(filename: filename) }
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        guard let scaled = CardImageStore.scaled(source, maxPixel: min(max(width, height), SourceLimits.maxImageLongEdge)),
              let encoded = try? CardImageStore.encode(scaled, png: hasAlpha)
        else { throw SourceError.unreadable(filename: filename) }
        return ImageSource(data: encoded, mediaType: hasAlpha ? "image/png" : "image/jpeg", filename: filename)
    }

    static func image(at url: URL) throws -> ImageSource {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw SourceError.unreadable(filename: url.lastPathComponent) }
        return try image(from: data, filename: url.lastPathComponent)
    }

    // MARK: Text

    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "text"]

    static func text(from data: Data, name: String?) throws -> TextSource {
        let label = name ?? "Pasted text"
        guard data.count <= SourceLimits.maxTextBytes else { throw SourceError.unreadable(filename: label) }
        // UTF-8 first; UTF-16 only when the file says so (a byte order mark), since almost any bytes of
        // even length are "valid" UTF-16; and Latin-1 for old files, which accepts anything.
        let hasUTF16Mark = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard let text = String(data: data, encoding: .utf8)
            ?? (hasUTF16Mark ? String(data: data, encoding: .utf16) : nil)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw SourceError.unreadable(filename: label)
        }
        return try pastedText(text, name: name)
    }

    /// Notes typed or pasted in.
    static func pastedText(_ text: String, name: String? = nil) throws -> TextSource {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceError.empty(filename: name ?? "Pasted text") }
        return TextSource(text: trimmed, name: name)
    }

    static func text(at url: URL) throws -> TextSource {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw SourceError.unreadable(filename: url.lastPathComponent) }
        return try text(from: data, name: url.lastPathComponent)
    }

    // MARK: Any file

    /// A dropped or chosen file, whichever kind it is.
    static func source(at url: URL) throws -> GenerationSource {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true { return .pdf(try pdf(at: url)) }
        if type?.conforms(to: .image) == true { return .image(try image(at: url)) }
        if textExtensions.contains(url.pathExtension.lowercased()) || type?.conforms(to: .text) == true { return .text(try text(at: url)) }
        throw SourceError.unsupported(filename: name)
    }
}
