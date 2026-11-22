import SwiftUI
import AVFoundation

/// The invitation scanner: the camera behind a frame, what to aim at, and a
/// way out. Before the system asks for the camera, a sentence says what it is
/// for. Reads QR codes only and hands back the first text it finds.
struct QRScannerView: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized:
                    scanner
                case .notDetermined:
                    explanation(asking: true)
                default:
                    explanation(asking: false)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var scanner: some View {
        ZStack {
            CameraPreview { text in
                onFound(text)
                dismiss()
            }
            .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 250, height: 250)
                .shadow(color: .black.opacity(0.3), radius: 8)

            VStack {
                Spacer()
                Text(L("scanner.hint"))
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .glassCapsuleLabel()
                    .padding(.bottom, 40)
            }
        }
    }

    private func explanation(asking: Bool) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text(L("scanner.camera_reason"))
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if asking {
                Button(L("enroll.submit")) {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        status = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                }
                .glassProminentButton()
                .controlSize(.large)
            } else if let settings = URL(string: UIApplication.openSettingsURLString) {
                Link(destination: settings) { Image(systemName: "gear") }
                    .font(.title2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder func glassCapsuleLabel() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}

/// AVFoundation's preview with a QR metadata output.
private struct CameraPreview: UIViewRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = context.coordinator.session
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done,
                  let text = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first
            else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound(text)
        }
    }
}
