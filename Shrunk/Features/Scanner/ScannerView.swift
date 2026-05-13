import SwiftUI
import AVFoundation

struct ScannerView: View {
    @StateObject private var processor = BarcodeProcessor()
    @StateObject private var vm = ScannerViewModel()

    @State private var pulseOuter: CGFloat = 1.0
    @State private var pulseInner: CGFloat = 0.96
    @State private var scanLineY: CGFloat = -1

    private let reticleSize: CGFloat = 260

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if processor.isAuthorized {
                CameraPreviewLayer(session: processor.session)
                    .ignoresSafeArea()
                dimMask
                reticle
                    .frame(width: reticleSize, height: reticleSize)
                searchingPill
            } else {
                permissionPrompt
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if processor.isAuthorized && !vm.recentBarcodes.isEmpty {
                    bottomCard
                }
            }
        }
        .onAppear { processor.bootstrap() }
        .onDisappear { processor.stop() }
        .onChange(of: processor.detectedBarcode) { _, new in
            if let new { vm.handle(barcode: new) }
        }
        .sheet(item: Binding<ScannedBarcode?>(
            get: { vm.presentedBarcode.map { ScannedBarcode(id: $0) } },
            set: { vm.presentedBarcode = $0?.id }
        )) { wrapper in
            ResultView(barcode: wrapper.id)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Couldn't start camera",
               isPresented: Binding(
                   get: { processor.error != nil && processor.isAuthorized },
                   set: { if !$0 { processor.error = nil } }
               ),
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(processor.error ?? "") })
        .preferredColorScheme(.dark)
    }

    // MARK: - Camera overlays

    private var dimMask: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .frame(width: reticleSize, height: reticleSize)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }

    private var reticle: some View {
        ZStack {
            // Outer breathing ring
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.shrunkRed.opacity(0.55), lineWidth: 1.5)
                .scaleEffect(pulseOuter)
                .opacity(2 - Double(pulseOuter))

            // Static frame
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.shrunkRed.opacity(0.85), lineWidth: 2)
                .scaleEffect(pulseInner)

            // Corner brackets — heavier than spec, more cinematic
            ForEach(0..<4, id: \.self) { idx in
                Bracket(corner: Bracket.Corner(rawValue: idx)!,
                        length: 36, width: 4, inset: 14)
                    .stroke(Color.shrunkRed,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }

            // Scan beam — gradient for soft falloff
            GeometryReader { geo in
                LinearGradient(
                    colors: [Color.shrunkRed.opacity(0),
                             Color.shrunkRed,
                             Color.shrunkRed.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 2.5)
                .blur(radius: 1)
                .position(x: geo.size.width / 2,
                          y: max(2, scanLineY * geo.size.height))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                pulseOuter = 1.18
            }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulseInner = 1.0
            }
            withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) {
                scanLineY = 1
            }
        }
    }

    private var searchingPill: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.shrunkRed)
                    .frame(width: 6, height: 6)
                Text("Searching for barcode")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, reticleSize / 2 + 80 + 100)
            .opacity(processor.isRunning ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: processor.isRunning)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                Text("SHRUNK")
                    .font(.system(size: 12, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            if processor.hasTorch {
                Button {
                    processor.toggleTorch()
                } label: {
                    Image(systemName: processor.torchOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(processor.torchOn ? Color.yellow : .white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(processor.torchOn ? "Turn flash off" : "Turn flash on")
            }
        }
        .padding(.horizontal, ShrunkTheme.Spacing.md)
        .padding(.top, ShrunkTheme.Spacing.sm)
        .frame(height: 56)
    }

    // MARK: - Recent scans bottom card

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .heavy))
                Text("RECENT")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.0)
            }
            .foregroundStyle(.white.opacity(0.65))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.recentBarcodes, id: \.self) { code in
                        Button {
                            vm.handle(barcode: code)
                        } label: {
                            Text(code)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(ShrunkTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
        .padding(.horizontal, ShrunkTheme.Spacing.md)
        .padding(.bottom, ShrunkTheme.Spacing.md)
    }

    // MARK: - Permission fallback

    private var permissionPrompt: some View {
        VStack(spacing: ShrunkTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.shrunkRed.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "camera.metering.unknown")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.shrunkRed)
            }
            Text("Camera access needed")
                .font(.shrunkTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(processor.error ?? "Open Settings → Shrunk and turn on Camera to start scanning.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            ShrunkButton("Open Settings", icon: "gear") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.top, ShrunkTheme.Spacing.sm)
        }
    }
}

// MARK: - Corner bracket shape

private struct Bracket: Shape {
    enum Corner: Int { case topLeft = 0, topRight, bottomRight, bottomLeft }
    let corner: Corner
    let length: CGFloat
    let width: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = rect.insetBy(dx: inset, dy: inset)
        switch corner {
        case .topLeft:
            p.move(to: CGPoint(x: r.minX, y: r.minY + length))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        case .topRight:
            p.move(to: CGPoint(x: r.maxX - length, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))
        case .bottomRight:
            p.move(to: CGPoint(x: r.maxX, y: r.maxY - length))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        case .bottomLeft:
            p.move(to: CGPoint(x: r.minX + length, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - length))
        }
        return p
    }
}

#Preview {
    ScannerView()
}
