import Foundation
import AVFoundation
import CoreImage
import UIKit
import SaidKit

/// The camera behind slide capture (screen 05).
///
/// **VIDEO-ONLY, and that is the whole constraint.** Adding an audio input to an `AVCaptureSession`
/// reconfigures the shared `AVAudioSession` and kills the recording in progress. There is a video
/// input and a photo output here and nothing else — no audio device, no movie output, no
/// `usesApplicationAudioSession` fiddling. A slide capture must be invisible to the microphone.
@MainActor
final class SlideCamera: NSObject, ObservableObject {

    /// What Vision can read through the lens right now — shown before the shutter so the user knows
    /// the shot is legible without taking it.
    @Published private(set) var livePreviewText: String?
    @Published private(set) var isAuthorized = false
    @Published private(set) var failure: String?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.nikhil.said.camera")

    private var captureContinuation: CheckedContinuation<CGImage?, Never>?
    /// Throttles the live read-out. OCR every frame would cook the phone for no benefit.
    private var lastPreviewOCR: CFTimeInterval = 0
    private var previewBusy = false
    private var previewEnabled = false

    // MARK: - Permission + setup

    func requestAccessAndConfigure() async {
        // Asked HERE, on first slide capture — never at first run. A camera prompt during onboarding
        // for a feature the user has not reached is how you get denied by default.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: isAuthorized = true
        case .notDetermined: isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default: isAuthorized = false
        }
        guard isAuthorized else {
            failure = "Said needs camera access to read slides. You can turn it on in Settings."
            return
        }
        configure()
    }

    private func configure() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            failure = "No camera available."
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
    }

    func start() {
        guard isAuthorized else { return }
        previewEnabled = true
        queue.async { [session] in if !session.isRunning { session.startRunning() } }
    }

    /// Stop everything, including the live OCR. A camera left sampling in the background is a
    /// battery leak the user cannot see.
    func stop() {
        previewEnabled = false
        livePreviewText = nil
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    // MARK: - Shutter

    /// Take a full-resolution photo. Returns the corrected image, or nil if the capture failed.
    func capture() async -> CGImage? {
        guard isAuthorized, session.isRunning else { return nil }
        let raw: CGImage? = await withCheckedContinuation { cont in
            captureContinuation = cont
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
        guard let raw else { return nil }
        // Phase 2's helper: finds the slide's quad and flattens it, and returns the ORIGINAL
        // unchanged when it can't. A capture is never lost to a failed correction.
        return await SlideOCR.correctingPerspective(of: raw)
    }
}

// MARK: - Photo delegate

extension SlideCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let image = photo.cgImageRepresentation()
        Task { @MainActor in
            let cont = self.captureContinuation
            self.captureContinuation = nil
            cont?.resume(returning: image)
        }
    }
}

// MARK: - Live preview OCR

extension SlideCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        Task { @MainActor in
            // Roughly twice a second, and never overlapping. This is a battery item.
            guard self.previewEnabled, !self.previewBusy, now - self.lastPreviewOCR > 0.5 else { return }
            self.lastPreviewOCR = now
            self.previewBusy = true
            defer { self.previewBusy = false }
            guard let cg = CGImage.fromPixelBuffer(pixels) else { return }
            // `.fast` for the read-out; the frame that lands on the timeline is read `.accurate`.
            let text = await SlideOCR.recognize(cgImage: cg, fast: true)
            guard self.previewEnabled else { return }
            self.livePreviewText = text
        }
    }
}
