import Foundation

/// Which copied text is worth offering a card for. Pure rules, so they can be tested.
enum CopyCandidate {
    /// A word or short phrase: longer text is a sentence or a paragraph, not a card.
    static let maxCharacters = 60
    static let maxWords = 5
    /// What a "Make a card" prefill keeps of text copied in full, when the user asked for it anyway.
    static let maxPrefill = 300

    /// The text trimmed, or nil if it isn't a word or short phrase: blank, over 60 characters, more than
    /// 5 words, or on more than one line.
    static func text(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isNewline), trimmed.count <= maxCharacters else { return nil }
        guard trimmed.split(whereSeparator: \.isWhitespace).count <= maxWords else { return nil }
        return trimmed
    }

    /// What to put in the Front field when the user asks for a card from whatever was copied: the first
    /// line, at most 300 characters.
    static func prefill(from raw: String?) -> String {
        let firstLine = raw?.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(maxPrefill))
    }

    /// Password managers and other apps mark what they copy as secret or short-lived with these types
    /// (nspasteboard.org). Those copies are never offered.
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
    ]

    static func isConcealed(typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains { concealedTypes.contains($0) }
    }

    /// Copied text arrives as one of these.
    static let textTypes: Set<String> = ["public.utf8-plain-text", "NSStringPboardType", "public.plain-text", "public.text"]

    static func hasText(typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains { textTypes.contains($0) }
    }
}

/// Stops the same text being offered twice in a row: copy a word, then copy it again a moment later (to
/// paste it somewhere), and only the first copy gets an offer.
struct CopyOfferTracker: Equatable, Sendable {
    static let window: TimeInterval = 8

    private var lastText: String?
    private var lastDate: Date?

    mutating func shouldOffer(_ text: String, at now: Date) -> Bool {
        if lastText == text, let lastDate, now.timeIntervalSince(lastDate) < Self.window { return false }
        lastText = text
        lastDate = now
        return true
    }
}

/// What the notch says about copying: an offer to make a card, or that one was just made.
struct CopyBanner: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `text` is nil when the offer is made without reading what was copied (see `CopyToCardService`).
        case offer(text: String?)
        case added(deckName: String)
    }

    var kind: Kind
    var expiresAt: Date

    static let offerDuration: TimeInterval = 6
    static let addedDuration: TimeInterval = 2.5

    var isOffer: Bool {
        if case .offer = kind { return true }
        return false
    }

    /// The drawn notch's line, e.g. `Copied “sin embargo”` or `Copied text`.
    var offerLabel: String {
        guard case .offer(let text) = kind else { return "" }
        return text.map { "Copied “\($0)”" } ?? "Copied text"
    }

    /// What VoiceOver says when it appears.
    var announcement: String {
        switch kind {
        case .offer(let text):
            let what = text.map { "“\($0)”" } ?? "text"
            return "Copied \(what). Press Control Option C, or click the notch, to make a card."
        case .added(let deckName):
            return "Added to \(deckName)"
        }
    }
}

/// The one offer on screen, shared by every display's notch. Offers and confirmations come and go on
/// their own; nothing ticks, the notch asks `expireIfNeeded` when its timer fires.
@MainActor
final class CopyOfferStore: ObservableObject {
    @Published private(set) var banner: CopyBanner?

    func offer(text: String?, at now: Date = Date()) {
        banner = CopyBanner(kind: .offer(text: text), expiresAt: now.addingTimeInterval(CopyBanner.offerDuration))
    }

    func showAdded(deckName: String, at now: Date = Date()) {
        banner = CopyBanner(kind: .added(deckName: deckName), expiresAt: now.addingTimeInterval(CopyBanner.addedDuration))
    }

    func dismiss() {
        if banner != nil { banner = nil }
    }

    func expireIfNeeded(at now: Date = Date()) {
        if let banner, now >= banner.expiresAt { self.banner = nil }
    }
}
