import SwiftUI
import UIKit

/// The entry's card — its shared side, in the member's own words — handed to
/// the system's share sheet: the poster as the picture, the card as text, and
/// the address it is read at (its public page once published, else what it
/// is about).
///
/// Offered only while the card is the face shown and has something written on
/// it. Nothing of the fiche leaves: no note, no highlight, no summary, nothing
/// Maurice wrote. What goes out in public is the member's or the work's own,
/// never text an AI generated.
struct EntryShareButton: View {
    let entry: ShelfEntry
    let card: EntryDetail.Shared

    @State private var preparing = false

    var body: some View {
        Button {
            Task { await share() }
        } label: {
            if preparing {
                ProgressView().tint(CarnetTheme.inkMute).frame(width: 40, height: 40)
            } else {
                GridIconGlyph(systemName: "square.and.arrow.up", size: 40)
            }
        }
        .buttonStyle(.plain)
        .disabled(preparing)
        .accessibilityLabel(L("entry.share.card"))
    }

    @MainActor
    private func share() async {
        preparing = true
        defer { preparing = false }
        var items: [Any] = []
        if let poster = await CoverImage.uiImage(shelf: entry) { items.append(poster) }
        items.append(CardText.text(entry: entry, card: card))
        if let link = CardText.link(entry: entry, card: card) { items.append(link) }
        SystemShare.present(items)
    }
}

/// The card as plain text: its title and who made the work, then what the
/// member wrote, its citations and marks read as words.
enum CardText {
    /// Whether there is anything written on the card to share.
    static func hasText(_ card: EntryDetail.Shared?) -> Bool {
        guard let card else { return false }
        return !SharedBody.withoutTitle(card.body, title: card.title).isEmpty
    }

    static func text(entry: ShelfEntry, card: EntryDetail.Shared) -> String {
        let title = card.title.flatMap { $0.isEmpty ? nil : $0 } ?? entry.title
        let head = entry.byline.map { "\(title) — \($0)" } ?? title
        let body = plain(SharedBody.withoutTitle(card.body, title: card.title))
        return "\(head)\n\n\(body)"
    }

    /// The public page once published; else the original, for an article.
    static func link(entry: ShelfEntry, card: EntryDetail.Shared) -> URL? {
        for raw in [card.state == .published ? card.publicUrl : nil, entry.source?.url] {
            if let raw, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true { return url }
        }
        return nil
    }

    /// `[[target|label]]` → label, `[[target]]` → target, `[text](url)` →
    /// text, `**` and `__` dropped.
    static func plain(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: #"\[\[[^\]|]*\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return s
    }
}

/// The system's share sheet, over whatever is on screen.
enum SystemShare {
    @MainActor
    static func present(_ items: [Any]) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
              var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // An iPad shows it as a popover: anchored at the top of the screen.
        sheet.popoverPresentationController?.sourceView = window
        sheet.popoverPresentationController?.sourceRect = CGRect(x: window.bounds.midX, y: 60, width: 0, height: 0)
        top.present(sheet, animated: true)
    }
}
