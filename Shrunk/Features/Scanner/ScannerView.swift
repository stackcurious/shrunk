import SwiftUI
import AVFoundation

struct ScannerView: View {
    @StateObject private var processor = BarcodeProcessor()
    @StateObject private var vm = ScannerViewModel()

    @State private var pulseInner: CGFloat = 0.96
    @State private var scanLineY: CGFloat = -1

    private let reticleSize: CGFloat = 260

    var body: some View {
        cameraChrome
            // Applied here, *inside* the presentation modifiers below, so it
            // covers the camera chrome and nothing else. As the outermost
            // modifier it also flowed into the Result sheet, which is a content
            // screen and has to follow the device (spec §3).
            .environment(\.colorScheme, .dark)
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
    }

    /// Everything that draws over the camera. Dark by construction — the feed
    /// is full-bleed black — and dark *only here*: `MainTabsView` no longer
    /// flips the window's scheme when this tab is selected, which used to
    /// cross-fade the whole app on every tab switch (review S2).
    private var cameraChrome: some View {
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
            // One stroke, plus the brackets. There used to be three concentric
            // rounded rects here — the breathing ring, this frame and the dim
            // mask's cutout edge — which read as a stack of boxes (review N3).
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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
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
                    .font(.subheadline.weight(.semibold))
                Text("SHRUNK")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            if processor.hasTorch {
                Button {
                    processor.toggleTorch()
                } label: {
                    Image(systemName: processor.torchOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.headline)
                        .foregroundStyle(processor.torchOn ? Color.yellow : .primary)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(processor.torchOn ? "Turn flash off" : "Turn flash on")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(height: 56)
    }

    // MARK: - Recent scans bottom card

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recent", systemImage: "clock.arrow.circlepath")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            // The chips used to be hard-clipped at the card's padding edge, so
            // the third one read as truncated text rather than a scrollable
            // row. Content margins give it a gutter it can scroll under (N3).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.recentBarcodes, id: \.self) { code in
                        Button {
                            vm.handle(barcode: code)
                        } label: {
                            Text(code)
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.primary)
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .mask(
                LinearGradient(
                    stops: [.init(color: .black, location: 0),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Permission fallback

    private var permissionPrompt: some View {
        ContentUnavailableView {
            Label("Camera access needed", systemImage: "camera.metering.unknown")
        } description: {
            Text(processor.error ?? "Open Settings → Shrunk and turn on Camera to start scanning.")
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
