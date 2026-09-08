import SwiftUI
import AVFoundation
import SaidKit

/// Screen 05 — Slide.
///
/// The Mac reads slides off the screen. A phone in a lecture theatre reads them off the wall. Same
/// Vision pass, same event on the timeline, same words in the search index.
///
/// **Recording never pauses while this is open.** The amber timestamp is where the frame lands.
struct SlideCaptureScreen: View {
    @ObservedObject var model: RecordingModel
    @StateObject private var camera = SlideCamera()
    var onClose: () -> Void

    @State private var capturing = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreview(session: camera.session).ignoresSafeArea()
            }

            // The shutter flash, so a capture feels like it happened.
            if flash { Color.white.ignoresSafeArea().transition(.opacity) }

            VStack {
                topBar
                Spacer()
                if let failure = camera.failure { permissionNotice(failure) }
                footer
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await camera.requestAccessAndConfigure()
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    private var topBar: some View {
        HStack {
            // Recording continues behind the camera — say so, or taking a slide feels risky.
            HStack(spacing: 8) {
                Circle().fill(Palette.amber).frame(width: 8, height: 8)
                Text("Still recording")
                    .font(Theme.ui(12, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(.black.opacity(0.45)).clipShape(Capsule())
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private func permissionNotice(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(14)).foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(18)
            .background(.black.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 30)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            // The live read-out: what Vision can see through the lens right now, so the user knows
            // the shot is legible BEFORE taking it.
            if let preview = camera.livePreviewText, !preview.isEmpty {
                HStack(spacing: 8) {
                    Blob(size: 8, color: Palette.amber)
                    Text("“\(preview.prefix(90))”")
                        .font(Theme.mono(11))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .accessibilityLabel("Camera reads: \(preview)")
            }

            HStack {
                Button("Cancel", action: onClose)
                    .font(Theme.ui(14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, alignment: .leading)

                Spacer()

                // The shutter IS the record blob again — the same drawing, its third appearance.
                Button {
                    Task { await shoot() }
                } label: {
                    BlobPair(size: 18)
                        .frame(width: 70, height: 70)
                        .background(Palette.violet)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                        .opacity(capturing ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(capturing || !camera.isAuthorized)
                .accessibilityLabel("Capture slide")
                .accessibilityHint("Adds this slide to the transcript at the current time")

                Spacer()

                // Amber, because it is where the frame lands on the timeline.
                Text(DocumentBuilder.timestamp(model.elapsed))
                    .font(Theme.mono(13))
                    .foregroundStyle(Palette.amber)
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 34)
        }
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func shoot() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }

        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        guard let image = await camera.capture() else {
            withAnimation { flash = false }
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { flash = false }

        await model.appendFrame(image)
        onClose()
    }
}

/// The camera preview layer. UIKit because `AVCaptureVideoPreviewLayer` has no SwiftUI equivalent —
/// exactly the kind of case §4 allows a `UIViewRepresentable` for.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
