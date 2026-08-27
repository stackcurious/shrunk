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

    /// Standard UPC-E zero-suppression expansion to UPC-A, then padded to the
    /// GTIN-13 form the Worker's `normalizeGTIN` accepts (I2). AVFoundation
    /// delivers `.upce` codes as the raw 8-digit compressed string, not
    /// expanded — unlike UPC-A, which it already reports as `.ean13`. Without
    /// this, an 8-digit UPC-E scan (common on small single-serve packages)
    /// fails `normalizeGTIN`'s 12/13/14-digit check on every request,
    /// including the eventual `/v1/observations` contribute submission, which
    /// needs a real canonical gtin to succeed — mapping the 400 alone would
    /// only get the user to the Contribute screen, not through it.
    ///
    /// Digits: N (number system, 0 or 1) D1 D2 D3 D4 D5 D6 C (check digit).
    /// The expansion rule is keyed on D6 per the GS1 tables; each branch is a
    /// straight positional zero-insertion with the check digit carried over
    /// unchanged. Returns nil for anything that isn't exactly 8 digits with a
    /// valid number system digit.
    nonisolated static func expandUPCEToGTIN13(_ upce: String) -> String? {
        guard upce.count == 8 else { return nil }
        let digits = upce.compactMap(\.wholeNumberValue)
        guard digits.count == 8 else { return nil }
        let n = digits[0]
        guard n == 0 || n == 1 else { return nil }
        let d1 = digits[1], d2 = digits[2], d3 = digits[3]
        let d4 = digits[4], d5 = digits[5], d6 = digits[6]
        let check = digits[7]

        let upcA: [Int]
        switch d6 {
        case 0, 1, 2: upcA = [n, d1, d2, d6, 0, 0, 0, 0, d3, d4, d5, check]
        case 3:       upcA = [n, d1, d2, d3, 0, 0, 0, 0, 0, d4, d5, check]
        case 4:       upcA = [n, d1, d2, d3, d4, 0, 0, 0, 0, 0, d5, check]
        default:      upcA = [n, d1, d2, d3, d4, d5, 0, 0, 0, 0, d6, check]
        }
        // UPC-A (12 digits) -> GTIN-13 is a leading-zero pad, matching the
        // Worker's `normalizeGTIN` 12-digit branch.
        return "0" + upcA.map(String.init).joined()
    }

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
              let raw = object.stringValue,
              !raw.isEmpty else { return }

        // UPC-E arrives compressed (8 digits) and unexpanded — canonicalise it
        // to a GTIN-13 before it ever reaches the API (I2). If expansion fails
        // (malformed read), drop the detection rather than emit a barcode the
        // backend can never resolve.
        let value: String
        if object.type == .upce {
            guard let expanded = Self.expandUPCEToGTIN13(raw) else { return }
            value = expanded
        } else {
            value = raw
        }

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
