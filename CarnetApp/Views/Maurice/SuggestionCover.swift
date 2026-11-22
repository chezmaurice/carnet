import SwiftUI

// A suggestion's poster and kind, as the Maurice app draws them
// (maurice/app/Maurice/Views/CarnetSuggestions.swift: SuggestionCover, KindPill).

enum SuggestionKind {
    static let known: Set<String> = ["movies", "series", "books", "music", "podcasts", "games", "people", "articles", "posts"]

    static func label(_ kind: String) -> String {
        known.contains(kind) ? L("suggest.kind.\(kind)") : "Entry"
    }

    /// The glyph that stands in for a cover.
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "movies": return "film"
        case "series": return "tv"
        case "books": return "book"
        case "music": return "music.note"
        case "podcasts": return "mic"
        case "games": return "gamecontroller"
        case "people": return "person"
        case "articles": return "doc.text"
        default: return "doc"
        }
    }
}

/// A portrait round, a sleeve square, a poster 2:3; the kind's glyph until it
/// loads, or when there is none.
struct SuggestionCover: View {
    let image: String?
    let kind: String
    var width: CGFloat = 46

    private var url: URL? {
        guard let image, !image.isEmpty else { return nil }
        if image.hasPrefix("http") { return URL(string: image) }
        return URL(string: CarnetAPI.baseURL + image)
    }

    private var height: CGFloat { kind == "music" || kind == "podcasts" || kind == "people" ? width : width * 3 / 2 }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(kind == "people" ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            CarnetTheme.inkMute.opacity(0.12)
            Image(systemName: SuggestionKind.symbol(kind))
                .font(.system(size: width * 0.36))
                .foregroundStyle(CarnetTheme.inkMute)
        }
    }
}

/// The kind of entry, written out, with its glyph: two offers can share a title.
struct SuggestionKindPill: View {
    let kind: String

    var body: some View {
        Label(SuggestionKind.label(kind), systemImage: SuggestionKind.symbol(kind))
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(CarnetTheme.inkSoft)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(CarnetTheme.inkMute.opacity(0.12)))
            .fixedSize()
    }
}
