import SwiftUI

/// One garden entry — its two faces (published card, working fiche), each
/// openable where it lives: in the browser to read, in Working Copy or
/// Obsidian to write. The entry "Sugar" offers both its card and its fiche.
struct GardenEntryView: View {
    let entry: GardenEntry
    /// Garden owner — the default repo/vault name for the editor links.
    let username: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var collection: GardenCollection? { GardenCollection(rawValue: entry.collection) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18)).foregroundStyle(CarnetTheme.inkSoft)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.top, 6)

                header

                if let card = entry.card {
                    faceCard(title: "Card", subtitle: "The published page", face: card,
                             system: "rectangle.portrait.on.rectangle.portrait")
                }
                if let fiche = entry.fiche {
                    faceCard(title: "Fiche", subtitle: "The working notes behind it", face: fiche,
                             system: "note.text")
                }
                if entry.card == nil && entry.fiche == nil {
                    GridMessage(text: "This entry has no files.")
                }
            }
            .padding(.bottom, 24)
        }
        .background(CarnetTheme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(entry: entry, width: 78, height: 110)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(CarnetTheme.display(22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(CarnetTheme.ink)
                HStack(spacing: 6) {
                    if let collection {
                        Image(systemName: collection.symbol).font(.system(size: 11))
                        Text(collection.label)
                    } else {
                        Text(entry.collection)
                    }
                    if !entry.date.isEmpty { Text("· \(entry.date)") }
                }
                .font(CarnetTheme.sans(13))
                .foregroundStyle(CarnetTheme.inkMute)
                .padding(.top, 4)
                if !entry.tags.isEmpty {
                    Text(entry.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(CarnetTheme.mono(11))
                        .foregroundStyle(CarnetTheme.inkSoft)
                        .padding(.top, 10)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: - Face card (read in browser · edit in WC / Obsidian)

    @ViewBuilder private func faceCard(title: String, subtitle: String,
                                       face: GardenEntryFace, system: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: system).font(.system(size: 13)).foregroundStyle(CarnetTheme.inkSoft)
                GridLabel(title)
                Spacer(minLength: 0)
                Text(face.file)
                    .font(CarnetTheme.mono(9.5))
                    .foregroundStyle(CarnetTheme.inkMute)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(subtitle)
                .font(CarnetTheme.sans(12.5))
                .foregroundStyle(CarnetTheme.inkMute)
                .padding(.top, 4)

            VStack(spacing: 0) {
                if let path = face.webPath {
                    linkRow("Read in browser", system: "safari") {
                        Task { if let url = await GardenLinks.webURL(path) { openURL(url) } }
                    }
                    GridRule()
                }
                if let url = GardenLinks.workingCopyURL(file: face.file, username: username) {
                    linkRow("Edit in Working Copy", system: "square.and.pencil") { openURL(url) }
                    GridRule()
                }
                if let url = GardenLinks.obsidianURL(file: face.file, username: username) {
                    linkRow("Open in Obsidian", system: "diamond") { openURL(url) }
                    GridRule()
                }
                // For the Mac (or any device where the vault lives elsewhere):
                // the link travels via the clipboard / Universal Clipboard.
                if let url = GardenLinks.obsidianURL(file: face.file, username: username) {
                    linkRow("Copy Obsidian link", system: "doc.on.doc") {
                        UIPasteboard.general.string = url.absoluteString
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(CarnetTheme.ruleHard, lineWidth: 1))
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(CarnetTheme.surface)
        .overlay(Rectangle().strokeBorder(CarnetTheme.rule, lineWidth: 1))
        .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        .padding(.bottom, 12)
    }

    private func linkRow(_ title: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: system).font(.system(size: 14))
                Text(title).font(CarnetTheme.sans(14, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CarnetTheme.inkMute)
            }
            .foregroundStyle(CarnetTheme.ink)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
