import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct UploadView: View {
    @State private var selectedFileData: Data?
    @State private var originalFilename: String = ""
    @State private var editedFilename: String = ""
    @State private var isUploading = false
    @State private var showDocumentPicker = false
    @State private var showCalibrePicker = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadResult: String?
    @State private var recentUploads: [RecentUpload] = RecentUpload.loadAll()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Choose File", systemImage: "doc.badge.plus")
                    }

                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose Photo", systemImage: "photo.badge.plus")
                    }

                    Button {
                        showCalibrePicker = true
                    } label: {
                        Label("Add Book to Calibre", systemImage: "book.closed.fill")
                    }
                }

                if selectedFileData != nil {
                    Section("Selected File") {
                        LabeledContent("Original", value: originalFilename)

                        TextField("Filename", text: $editedFilename)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        LabeledContent("Size", value: ByteCountFormatter.string(
                            fromByteCount: Int64(selectedFileData?.count ?? 0),
                            countStyle: .file
                        ))

                        Button {
                            Task { await upload() }
                        } label: {
                            HStack {
                                Text("Upload")
                                Spacer()
                                if isUploading {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isUploading || editedFilename.isEmpty)
                    }
                }

                if let result = uploadResult {
                    Section {
                        Text(result)
                            .foregroundStyle(result.starts(with: "Error") ? .red : .green)
                            .font(.caption)
                    }
                }

                if !recentUploads.isEmpty {
                    Section("Recent Uploads") {
                        ForEach(recentUploads) { upload in
                            VStack(alignment: .leading) {
                                Text(upload.filename).font(.body)
                                Text(upload.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Upload")
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPicker(contentTypes: [.pdf, .image, .jpeg, .png]) { data, filename in
                    selectedFileData = data
                    originalFilename = filename
                    editedFilename = filename
                }
            }
            .sheet(isPresented: $showCalibrePicker) {
                DocumentPicker(contentTypes: [.pdf, .epub]) { data, filename in
                    Task { await addToCalibre(data: data, filename: filename) }
                }
            }
            .onChange(of: photoItem) {
                Task {
                    if let item = photoItem,
                       let data = try? await item.loadTransferable(type: Data.self) {
                        selectedFileData = data
                        let name = "photo-\(Date().formatted(.iso8601.year().month().day())).jpg"
                        originalFilename = name
                        editedFilename = name
                    }
                }
            }
        }
    }

    private func addToCalibre(data: Data, filename: String) async {
        isUploading = true
        defer { isUploading = false }

        do {
            let result = try await CarnetAPI.addBookToCalibre(data: data, filename: filename)
            if let bookId = result.bookId {
                uploadResult = "Added to Calibre: \(filename) (id: \(bookId))"
            } else {
                uploadResult = "Added to Calibre: \(filename)"
            }
        } catch {
            uploadResult = "Error: \(error.localizedDescription)"
        }
    }

    private func upload() async {
        guard let data = selectedFileData else { return }
        isUploading = true
        defer { isUploading = false }

        let mimeType = editedFilename.hasSuffix(".pdf") ? "application/pdf" : "image/jpeg"

        let item = QueueItem(
            id: UUID(),
            type: .fileUpload,
            createdAt: Date(),
            payload: QueuePayload(filename: editedFilename, mimeType: mimeType)
        )
        OfflineQueue.shared.enqueue(item, fileData: data)

        uploadResult = "Queued: \(editedFilename)"
        let recent = RecentUpload(filename: editedFilename, path: "queued", date: Date())
        recentUploads.insert(recent, at: 0)
        RecentUpload.saveAll(recentUploads)
        selectedFileData = nil
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.pdf, .image, .jpeg, .png]
    let onPick: (Data, String) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data, String) -> Void
        init(onPick: @escaping (Data, String) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) {
                onPick(data, url.lastPathComponent)
            }
        }
    }
}

// MARK: - Recent Uploads

struct RecentUpload: Identifiable, Codable {
    var id: String { path }
    let filename: String
    let path: String
    let date: Date

    private static let key = "recentUploads"
    private static let defaults = UserDefaults(suiteName: CarnetAPI.appGroupID) ?? .standard

    static func loadAll() -> [RecentUpload] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentUpload].self, from: data)) ?? []
    }

    static func saveAll(_ uploads: [RecentUpload]) {
        let trimmed = Array(uploads.prefix(20))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: key)
        }
    }
}
