import SwiftUI
import AVFoundation
import UIKit

struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView(session: session)
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.refresh(session: session)
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    /// Screenshot mode only — the stand-in for a camera feed the simulator
    /// cannot provide. Always nil in production.
    private var backdrop: CALayer?

    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        backgroundColor = .black
        if UITestingOverrides.isActive {
            backdrop = UITestingOverrides.installCameraBackdrop(on: self)
            return
        }
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop?.frame = bounds
    }

    func refresh(session: AVCaptureSession) {
        guard backdrop == nil else { return }
        if previewLayer.session !== session {
            previewLayer.session = session
        }
    }
}
