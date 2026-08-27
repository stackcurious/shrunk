import AVFoundation
import UIKit
import Combine

/// Still-photo capture for label contributions.
///
/// Same session discipline as `BarcodeProcessor`: `@Published` UI state lives on
/// the main actor, and every `AVCaptureSession` mutation happens on one private
/// serial queue. Session state is `nonisolated` because that queue *is* the
/// synchronization mechanism.
@MainActor
final class LabelCaptureController: NSObject, ObservableObject {
    @Published private(set) var isAuthorized = false
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published var error: String?

    nonisolated let session = AVCaptureSession()
    nonisolated private let queue = DispatchQueue(label: "com.shrunk.contribute.session")
    nonisolated private let output = AVCapturePhotoOutput()
    private nonisolated(unsafe) var configured = false

    private var onCapture: ((CGImage, Data) -> Void)?

    // MARK: - Lifecycle

    func bootstrap() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            startInternal()
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                self.isAuthorized = granted
                if granted { self.startInternal() }
                else { self.error = "Camera access is required to photograph a label." }
            }
        case .denied, .restricted:
            isAuthorized = false
            error = "Camera access denied. Enable it in Settings → Shrunk."
        @unknown default:
            isAuthorized = false
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor [weak self] in self?.isRunning = false }
        }
    }

    func capture(_ completion: @escaping (CGImage, Data) -> Void) {
        guard isRunning, !isCapturing else { return }
        isCapturing = true
        onCapture = completion
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .balanced
        queue.async { [weak self] in
            guard let self else { return }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Session-side (nonisolated, runs on `queue`)

    nonisolated private func startInternal() {
        queue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            Task { @MainActor [weak self] in self?.isRunning = running }
        }
    }

    nonisolated private func configureIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !configured else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            Task { @MainActor [weak self] in self?.error = "No camera available on this device." }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.error = message }
            return
        }

        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
    }

    // MARK: - Photo preparation

    /// Normalizes EXIF orientation and caps the longest edge at 1600 px, which
    /// keeps OCR accurate while holding uploads to a few hundred KB — far under
    /// the Worker's 5 MB cap.
    static func prepare(photoData: Data) -> (image: CGImage, jpeg: Data)? {
        guard let source = UIImage(data: photoData), source.size.width > 0, source.size.height > 0 else { return nil }

        let maxEdge: CGFloat = 1600
        let scale = min(1, maxEdge / max(source.size.width, source.size.height))
        let size = CGSize(
            width: (source.size.width * scale).rounded(),
            height: (source.size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // Redrawing also bakes in the orientation, so Vision sees an upright image.
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let cgImage = normalized.cgImage,
              let jpeg = normalized.jpegData(compressionQuality: 0.7) else { return nil }
        return (cgImage, jpeg)
    }
}

extension LabelCaptureController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        let message = error?.localizedDescription

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = false
            guard let data, let prepared = Self.prepare(photoData: data) else {
                self.error = message ?? "Couldn't save that photo — try again."
                return
            }
            let handler = self.onCapture
            self.onCapture = nil
            handler?(prepared.image, prepared.jpeg)
        }
    }
}
