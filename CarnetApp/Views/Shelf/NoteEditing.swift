import SwiftUI

// MARK: - Rewriting or taking off a note

/// A note of the member's side, opened to be rewritten: the entry it is on
/// (an entry shared with the member is written in its owner's garden) and
/// the note as it was read.
struct NoteEditTarget: Identifiable {
    let entry: ShelfEntry
    let item: MineItem
    var id: String { "\(entry.id)|\(item.id)" }
}

enum NoteEdits {
    /// Rewrite the note, then read again what it is on. A note that changed
    /// in the meantime has the page read again too, so what shows is current.
    static func save(_ target: NoteEditTarget, text: String, quote: String?, page: String?,
                     reload: @escaping () async -> Void) async throws {
        guard let id = target.item.serverId else { throw GardenAPI.NoteEditError.changed }
        do {
            try await GardenAPI.editNote(target.entry, noteId: id, text: text, quote: quote, page: page)
            await reload()
        } catch GardenAPI.NoteEditError.changed {
            await reload()
            throw GardenAPI.NoteEditError.changed
        }
    }

    static func delete(_ target: NoteEditTarget, reload: @escaping () async -> Void) async throws {
        guard let id = target.item.serverId else { throw GardenAPI.NoteEditError.changed }
        do {
            try await GardenAPI.deleteNote(target.entry, noteId: id)
            await reload()
        } catch GardenAPI.NoteEditError.changed {
            await reload()
            throw GardenAPI.NoteEditError.changed
        }
    }

    /// What went wrong, in the member's language.
    static func message(_ error: Error) -> String {
        switch error {
        case GardenAPI.NoteEditError.changed: return L("note.edit.changed")
        case GardenAPI.NoteEditError.forbidden: return L("note.edit.forbidden")
        case let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                       .cannotConnectToHost, .cannotFindHost, .dataNotAllowed].contains(e.code):
            return L("note.edit.offline")
        default: return EntryView.message(error)
        }
    }

    private static let dayIn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// « modifiée le 3 nov. 2026 », in the member's language.
    static func editedLine(_ day: String) -> String {
        guard let date = dayIn.date(from: String(day.prefix(10))) else { return L("note.edited", day) }
        return L("note.edited", date.formatted(.dateTime.day().month(.abbreviated).year().locale(AppLanguage.locale)))
    }
}

extension View {
    /// A note of the member's side, as the fiche and the « Notes » list show
    /// it: a tap opens it to be rewritten when the member may; a long press
    /// offers to take it off when they may (an owner, on what someone else
    /// signed on their shared entry, may only that).
    @ViewBuilder func noteActions(_ item: MineItem, onEdit: @escaping () -> Void,
                                  onDelete: @escaping () -> Void) -> some View {
        if item.canEdit || item.canDelete {
            self
                .contentShape(Rectangle())
                .onTapGesture { if item.canEdit { onEdit() } }
                .contextMenu {
                    if item.canEdit {
                        Button { onEdit() } label: { Label(L("note.edit.action"), systemImage: "pencil") }
                    }
                    if item.canDelete {
                        Button(role: .destructive) { onDelete() } label: { Label(L("note.edit.delete"), systemImage: "trash") }
                    }
                }
                .accessibilityAddTraits(item.canEdit ? .isButton : [])
                .accessibilityAction(named: Text(L("note.edit.delete"))) { if item.canDelete { onDelete() } }
        } else {
            self
        }
    }

    /// The sheet a note is rewritten in, and the question asked before one is
    /// taken off from its long-press menu. `reload` reads again what shows it.
    func noteEditing(_ editing: Binding<NoteEditTarget?>, deleting: Binding<NoteEditTarget?>,
                     reload: @escaping () async -> Void) -> some View {
        modifier(NoteEditingModifier(editing: editing, deleting: deleting, reload: reload))
    }
}

private struct NoteEditingModifier: ViewModifier {
    @Binding var editing: NoteEditTarget?
    @Binding var deleting: NoteEditTarget?
    let reload: () async -> Void
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { target in
                NoteSheet(title: target.entry.title,
                          offersPage: target.entry.source == nil || target.item.place?.page != nil,
                          locale: Locale(identifier: target.entry.locale ?? Locale.current.identifier),
                          editing: target.item,
                          onDelete: target.item.canDelete ? { try await NoteEdits.delete(target, reload: reload) } : nil) { text, quote, page in
                    try await NoteEdits.save(target, text: text, quote: quote, page: page, reload: reload)
                }
            }
            .confirmationDialog(L("note.edit.delete_confirm"),
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { target in
                Button(L("note.edit.delete"), role: .destructive) {
                    Task {
                        do { try await NoteEdits.delete(target, reload: reload) }
                        catch { failure = NoteEdits.message(error) }
                    }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("note.edit.delete_hint"))
            }
            .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(L("common.ok"), role: .cancel) {}
            }
    }
}
