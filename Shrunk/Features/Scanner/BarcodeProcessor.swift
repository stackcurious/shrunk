import AVFoundation
import UIKit
import Combine

/// Owns the AVCaptureSession, throttles barcode detections, and manages torch.
/// `@Published` UI state lives on @MainActor; AVCaptureSession configuration
/// runs on a private serial queue (Apple's documented safe pattern). Session
/// state is marked `nonisolated` because we guarantee single-queue access.
@MainActor
final class BarcodeProcessor: NSObject, ObservableObject {
    @Published private(set) var detectedBarcode: String?
    @Published private(set) var isAuthorized: Bool = false
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var hasTorch: Bool = false
    @Published var torchOn: Bool = false
    @Published var error: String?

    nonisolated let session = AVCaptureSession()
    nonisolated private let queue = DispatchQueue(label: "com.shrunk.scanner.session")

    private var lastEmission: Date = .distantPast
    private let throttleSeconds: TimeInterval = 2.0

    // Configuration state lives behind the queue, accessed only from
    // nonisolated session-touching methods. `nonisolated(unsafe)` is correct
    // because the queue's serial execution is the synchronization mechanism.
    private nonisolated(unsafe) var configured: Bool = false

    // UPC-A is delivered by iOS as EAN-13 with a leading "0", so .ean13 covers it.
    nonisolated private static let supportedTypes: [AVMetadataObject.ObjectType] = [
        .upce, .ean8, .ean13, .code128, .code39, .code93
    ]

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
                else { self.error = "Camera access is required to scan products." }
            }
        case .denied, .restricted:
            isAuthorized = false
            error = "Camera access denied. Enable it in Settings → Shrunk."
        @unknown default:
            isAuthorized = false
        }
    }

    func clearLastDetection() {
        detectedBarcode = nil
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor [weak self] in self?.isRunning = false }
        }
    }

    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            torchOn.toggle()
            device.torchMode = torchOn ? .on : .off
            device.unlockForConfiguration()
        } catch {
            self.error = "Couldn't toggle flash."
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
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            session.commitConfiguration()
            Task { @MainActor [weak self] in self?.error = "No camera available on this device." }
            return
        }
        let torchAvailable = device.hasTorch
        Task { @MainActor [weak self] in self?.hasTorch = torchAvailable }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.error = message }
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
            let available = metadataOutput.availableMetadataObjectTypes
            metadataOutput.metadataObjectTypes = Self.supportedTypes.filter { available.contains($0) }
        }

        session.commitConfiguration()
        configured = true
    }
}

extension BarcodeProcessor: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue,
              !value.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastEmission) > self.throttleSeconds else { return }
            self.lastEmission = now
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.detectedBarcode = value
        }
    }
}
