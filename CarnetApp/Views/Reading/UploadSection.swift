import SwiftUI
import UniformTypeIdentifiers

/// The Upload section — a single "Upload a file" button that sends an ebook to
/// the server, which recognises it (EPUB/PDF) and adds it to the Calibre library
/// (cover included). The book then appears in the library, un-chaptered, ready to
/// extract into chapters.
struct UploadSection: View {
    var onMenu: (() -> Void)? = nil

    @State private var importing = false
    @State private var uploading = false
    @State private var result: Result?

    private struct Result { let ok: Bool; let text: String }

    /// Types the backend accepts.
    private static let allowed: [UTType] = [.epub, .pdf]

    var body: some View {
        VStack(spacing: 0) {
            GridHeader(title: "Upload", kicker: "Add a book", menu: onMenu)
            GridRule()

            VStack(spacing: 18) {
                Spacer()

                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(CarnetTheme.inkHint)

                Text("Add an ebook to your library")
                    .font(CarnetTheme.sans(15))
                    .foregroundStyle(CarnetTheme.inkSoft)
                    .multilineTextAlignment(.center)

                GridButton(title: uploading ? "Uploading…" : "Upload a file",
                           systemImage: "arrow.up.doc", primary: true) {
                    importing = true
                }
                .disabled(uploading)

                if uploading {
                    ProgressView().controlSize(.small).tint(CarnetTheme.inkMute)
                }

                if let result {
                    Text(result.text)
                        .font(CarnetTheme.caption)
                        .foregroundStyle(result.ok ? CarnetTheme.inkSoft : CarnetTheme.accent)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer(); Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, CarnetTheme.pageHorizontalPadding)
        }
        .background(CarnetTheme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.allowed) { picked in
            if case .success(let url) = picked { Task { await upload(url) } }
        }
    }

    private func upload(_ url: URL) async {
        uploading = true
        result = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let added = try await CarnetAPI.addBookToCalibre(data: data, filename: url.lastPathComponent)
            result = Result(ok: true, text: "Added “\(added.filename ?? url.lastPathComponent)” to your library. Open Reading to find it.")
        } catch {
            result = Result(ok: false, text: "Couldn’t add that file.\n\(error.localizedDescription)")
        }
        uploading = false
    }
}
