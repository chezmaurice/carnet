import SwiftUI
import UniformTypeIdentifiers

/// The shelf's « + »: a new entry without a conversation. The member says in
/// their own words what they want to add — a work, a person — and gets back
/// what Maurice's conversations offer: the same rows, the same cards (keep,
/// pick the right one, search again, refine, dismiss). A row kept opens its
/// entry. Server: `POST /api/suggestions/from-text`.
///
/// Under the question, an EPUB or a PDF from the phone's files goes to the
/// household's library (`POST /api/v1/calibre/add`) and its book opens.
struct AddEntrySheet: View {
    /// Called with the entry kept, `<collection>/<locale>/<slug>`.
    var onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var batch: String?
    @State private var suggestions: [Suggestion] = []
    /// A search was made: an empty list then says nothing was found.
    @State private var asked = false
    @State private var looking = false
    @State private var error: String?
    @FocusState private var focused: Bool
    /// A book from the phone's files, on its way to the library.
    @State private var pickingFile = false
    @State private var sendingFile = false
    /// What the library said, when there is no book to open.
    @State private var fileNote: String?

    private var pending: [Suggestion] { suggestions.filter { !$0.isKept } }
    private var canAsk: Bool { !looking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    question
                    fileRow
                    if looking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                            GridLabel(L("add.looking"), size: 9.5)
                        }
                    }
                    if let error {
                        Text(error).font(CarnetTheme.sans(13)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !pending.isEmpty {
                        GridLabel(L("add.suggestions"), size: 9.5, color: CarnetTheme.inkSoft)
                        ForEach(pending) { s in
                            SuggestionCard(suggestion: s,
                                           onKeep: { await keep(s, candidate: $0, episodes: $1) },
                                           onEpisodes: { try? await MauriceAPI.episodes(s.id, feed: $0) },
                                           onSearch: { await search(s, query: $0) },
                                           onDismiss: { dismissRow(s) })
                        }
                    } else if asked && !looking && error == nil {
                        Text(L("add.none"))
                            .font(CarnetTheme.sans(13.5)).foregroundStyle(CarnetTheme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(CarnetTheme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
            .onAppear { focused = true }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.epub, .pdf]) { result in
                if case .success(let url) = result { Task { await addFile(url) } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// The bubble: the question, and the member's words.
    private var question: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("add.title"))
                .font(CarnetTheme.sans(17, weight: .semibold))
                .foregroundStyle(CarnetTheme.ink)
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("add.placeholder"), text: $text, axis: .vertical)
                    .font(CarnetTheme.sans(15))
                    .lineLimit(1...4)
                    // As tall as the button at least: one line sits centred
                    // on it; more lines grow upward, the button at the bottom.
                    .frame(minHeight: 34)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { Task { await ask() } }
                    .onChange(of: text) { _, new in
                        // A return typed in the vertical field is the submit.
                        if new.contains("\n") {
                            text = new.replacingOccurrences(of: "\n", with: "")
                            Task { await ask() }
                        }
                    }
                GridIconButton(systemName: "arrow.up", primary: canAsk, size: 34) {
                    Task { await ask() }
                }
                .disabled(!canAsk)
                .accessibilityLabel(L("add.go"))
            }
            .padding(12)
            .paper(.mine, in: RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CarnetTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(CarnetTheme.ruleHard, lineWidth: CarnetTheme.hairline))
        }
    }

    /// The other way in: a book the member has as a file.
    private var fileRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                GridButton(title: L("add.file"), systemImage: "doc.badge.plus", small: true) {
                    focused = false
                    fileNote = nil
                    pickingFile = true
                }
                .disabled(sendingFile || looking)
                if sendingFile {
                    ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                    GridLabel(L("add.file_sending"), size: 9.5)
                }
                Spacer(minLength: 0)
            }
            if let fileNote {
                Text(fileNote)
                    .font(CarnetTheme.sans(13)).foregroundStyle(CarnetTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func addFile(_ url: URL) async {
        sendingFile = true
        error = nil
        defer { sendingFile = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let added = try await CarnetAPI.addBookToCalibre(data: data, filename: url.lastPathComponent)
            if let id = added.bookId {
                dismiss()
                onOpen("calibre/\(id)")
            } else {
                fileNote = added.alreadyThere ? L("add.file_exists") : L("add.file_added")
            }
        } catch {
            self.error = EntryView.message(error)
        }
    }

    private func ask() async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !looking else { return }
        focused = false
        looking = true
        error = nil
        defer { looking = false; asked = true }
        do {
            let list = try await MauriceAPI.suggestions(fromText: words, locale: AppLanguage.chosen ?? Locale.current.language.languageCode?.identifier)
            batch = list.batch
            withAnimation { suggestions = list.suggestions }
        } catch {
            suggestions = []
            self.error = EntryView.message(error)
        }
    }

    private func keep(_ s: Suggestion, candidate: String?, episodes: [String]) async -> Bool {
        do {
            let kept = try await MauriceAPI.keep(s.id, candidate: candidate, episodes: episodes)
            if let ref = kept?.entry {
                dismiss()
                onOpen(ref)
            } else {
                await reread()
            }
            return true
        } catch {
            self.error = EntryView.message(error)
            return false
        }
    }

    /// Another look; the number found, or nil when the call failed.
    private func search(_ s: Suggestion, query: String?) async -> Int? {
        do {
            let found = try await MauriceAPI.search(s.id, query: query)
            await reread()
            return found
        } catch {
            self.error = EntryView.message(error)
            return nil
        }
    }

    private func dismissRow(_ s: Suggestion) {
        withAnimation { suggestions.removeAll { $0.id == s.id } }
        Task { try? await MauriceAPI.dismiss(s.id) }
    }

    private func reread() async {
        guard let batch, let list = try? await MauriceAPI.suggestions(batch: batch) else { return }
        withAnimation { suggestions = list.suggestions }
    }
}

/// The shelf's floating « + », bottom right.
struct AddEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(CarnetTheme.bg)
                .frame(width: 56, height: 56)
                .background(CarnetTheme.ink, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("add.button"))
    }
}
