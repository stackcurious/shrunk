import SwiftUI

/// Camera → OCR → confirm → upload. Dismisses itself once the Worker answers,
/// handing the result back so the presenting screen can show the toast.
struct LabelCaptureView: View {
    @StateObject private var camera = LabelCaptureController()
    @StateObject private var vm: ContributeViewModel
    @Environment(\.dismiss) private var dismiss

    private let onFinished: (SubmissionResult) -> Void

    init(gtin: String, onFinished: @escaping (SubmissionResult) -> Void) {
        _vm = StateObject(wrappedValue: ContributeViewModel(gtin: gtin))
        self.onFinished = onFinished
    }

    private var showsConfirmSheet: Bool {
        switch vm.step {
        case .confirm, .submitting: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreviewLayer(session: camera.session)
                    .ignoresSafeArea()
                guideOverlay
            } else {
                permissionPrompt
            }

            if vm.step == .reading {
                busyOverlay(message: "Reading the label…")
            }
        }
        .onAppear { camera.bootstrap() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: .constant(showsConfirmSheet)) {
            ContributeConfirmSheet(vm: vm) { vm.retake() }
                // A fixed 420 pt sheet clipped the Submit button at
                // accessibility sizes (review S15). `.medium` is the same
                // reading height on a phone and `.large` is there when the
                // content needs it.
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
        .onChange(of: vm.step) { _, step in
            if case .finished(let result) = step {
                onFinished(result)
                dismiss()
            }
        }
        .alert(
            "Couldn't reach Shrunk",
            isPresented: isShowingFailureAlert,
            actions: { Button("OK", role: .cancel) { vm.retake() } },
            message: { Text(failureMessage) }
        )
        .alert(
            "Camera problem",
            isPresented: isShowingCameraErrorAlert,
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(camera.error ?? "") }
        )
        .preferredColorScheme(.dark)
    }

    private var isFailed: Bool {
        if case .failed = vm.step { return true }
        return false
    }

    private var isShowingFailureAlert: Binding<Bool> {
        Binding(
            get: { isFailed },
            set: { isPresented in if !isPresented { vm.retake() } }
        )
    }

    private var isShowingCameraErrorAlert: Binding<Bool> {
        Binding(
            get: { camera.error != nil },
            set: { isPresented in if !isPresented { camera.error = nil } }
        )
    }

    private var failureMessage: String {
        if case .failed(let message) = vm.step { return message }
        return ""
    }

    // MARK: - Overlays

    private var guideOverlay: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(16)

            Spacer()

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
                .frame(height: 110)
                .padding(.horizontal, 20)

            Text("Line up the net weight — \"NET WT 12 OZ\"")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 16)

            Spacer()

            Button {
                camera.capture { image, jpeg in
                    Task { await vm.handleCapture(image: image, jpegData: jpeg) }
                }
            } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(Color.white).frame(width: 62, height: 62)
                }
            }
            .disabled(camera.isCapturing || !camera.isRunning)
            .accessibilityLabel("Take label photo")
            .padding(.bottom, 32)
        }
    }

    private func busyOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }

    private var permissionPrompt: some View {
        ContentUnavailableView {
            Label("Camera access needed", systemImage: "camera.fill")
        } description: {
            Text("Camera access is required to photograph a label.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
