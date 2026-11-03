import SwiftUI
import WidgetKit

/// One side of a flashcard. The back shows the answer text with an accent "Answer" label.
struct CardFace: View {
    enum Size {
        /// `hero` is Learn mode's one big card; `sprint` the Review sprint's.
        case small, medium, large, hero, sprint

        var frontFont: Font {
            switch self {
            case .small: .system(size: 20, weight: .bold)
            case .medium: .system(size: 28, weight: .bold)
            case .large: Theme.Typography.title
            case .hero: .system(size: 48, weight: .bold)
            case .sprint: .system(size: 34, weight: .bold)
            }
        }

        var backFont: Font {
            switch self {
            case .small: .system(size: 16, weight: .medium)
            case .medium: .system(size: 20, weight: .medium)
            case .large: .system(size: 22, weight: .medium)
            case .hero: .system(size: 32, weight: .medium)
            case .sprint: .system(size: 34, weight: .medium)
            }
        }
    }

    var text: String
    var isBack = false
    var size: Size = .large
    /// Long text shrinks down to this fraction of its size before it is cut off.
    var minimumScaleFactor: CGFloat = 0.6
    /// A picture for this side, shown above the text (or alone, if there is no text).
    var image: CardImage?
    /// The widget and the notch use the small copy of the picture, to stay within their memory.
    var useThumbnail = false
    var imageStore: CardImageStore = .shared

    @Environment(\.accentChoice) private var accent

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if let image {
                CardPicture(image: image, thumbnail: useThumbnail, store: imageStore)
            }
            // A picture with no words is shown alone, centered.
            if hasText || image == nil {
                Text(text)
                    .font(isBack ? size.backFont : size.frontFont)
                    .foregroundStyle(Theme.TextColor.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(image == nil ? nil : 4)
                    .minimumScaleFactor(minimumScaleFactor)
            }
            if isBack {
                Text("Answer")
                    .font(Theme.Typography.sectionLabel)
                    .foregroundStyle(accent.light)
                    .widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(text, isBack: isBack, image: image))
    }

    /// What VoiceOver reads: the front as written, and "Answer, ..." once the card is flipped. A
    /// blank card is announced as such instead of being silent. A picture adds its description; with
    /// none given, the text on that side stands in for it, and a picture alone is announced as one.
    static func accessibilityText(_ text: String, isBack: Bool, image: CardImage? = nil) -> String {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = spoken
        if let image {
            let description = image.altText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !description.isEmpty {
                body = spoken.isEmpty ? "Picture, \(description)" : "\(spoken), picture: \(description)"
            } else if spoken.isEmpty {
                body = "Picture"
            }
        }
        if isBack { return body.isEmpty ? "Answer, blank" : "Answer, \(body)" }
        return body.isEmpty ? "Blank card" : body
    }
}

/// A card's picture, scaled to fit with rounded corners. Fills whatever room the text leaves.
struct CardPicture: View {
    var image: CardImage
    var thumbnail: Bool
    var store: CardImageStore

    var body: some View {
        Group {
            if let picture = store.nsImage(for: image, thumbnail: thumbnail) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                // The file is missing (deleted outside the app): say so instead of leaving a hole.
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.TextColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true) // the face's own label describes it
    }
}

#Preview("CardFace") {
    HStack(spacing: 16) {
        CardFace(text: "la sobremesa", size: .small)
        CardFace(text: "lingering at the table after a meal", isBack: true, size: .small)
    }
    .frame(width: 360, height: 140)
    .appearancePreview()
}
