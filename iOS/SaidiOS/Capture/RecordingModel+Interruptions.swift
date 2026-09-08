import Foundation
import AVFoundation
import SaidKit

/// The four interruption paths.
///
/// Each is an INPUT to SaidKit's existing capture primitives — none of them introduces a second
/// state machine. Notifications can arrive off-main, and `SilenceMonitor` / `StallMonitor` /
/// `SessionClock` are plain structs with no locking, so every handler hops to the main actor before
/// touching them. (`CaptureGate` is NSLock-guarded and would be safe either way.)
extension RecordingModel {

    func installInterruptionObservers() {
        let centre = NotificationCenter.default

        // 1. A phone call, Siri, or another app taking the session.
        let interruption = centre.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            Task { @MainActor in
                switch type {
                case .began:
                    self?.handleInterruptionBegan()
                case .ended:
                    self?.handleInterruptionEnded(shouldResume: options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        }

        // 2. Headphones pulled, or a device otherwise going away.
        let route = centre.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            Task { @MainActor in
                switch reason {
                case .oldDeviceUnavailable:
                    // Do NOT silently fall back to the built-in mic mid-sentence: the user pulled
                    // their headphones out, and continuing on a different mic without saying so
                    // produces a transcript whose audio changes character halfway through.
                    self?.handleRouteLost()
                case .newDeviceAvailable, .routeConfigurationChange:
                    self?.noteRouteChanged()
                default:
                    break
                }
            }
        }

        // 3. The audio server died and took every engine with it.
        let reset = centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }

        retainObservers([interruption, route, reset])
    }

    // MARK: - 1. Interruption

    func handleInterruptionBegan() {
        guard isRecording, !isPaused else { return }
        // `.interruption` maps to SaidKit's `.manual`, never `.silence` — see `capturePauseReason`.
        // The system has already stopped our engine; we do not stop it again.
        pause(.interruption)
    }

    func handleInterruptionEnded(shouldResume: Bool) {
        guard isRecording, isPaused, currentPauseKind == .interruption else { return }
        guard shouldResume else {
            // The system is telling us NOT to resume — another app kept the session. Stay paused
            // and let the user decide, rather than fighting for the microphone.
            return
        }
        // Reactivating posts a route change with reason `.categoryChange`; `AudioCaptureMic`'s
        // route observer filters on reason precisely so this does not trigger a rebuild loop.
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { NSLog("[Recording] session reactivate failed: \(error)") }

        resume()
        // The engine may not have survived the interruption. A rebuild is cheap and idempotent;
        // a dead engine that nobody rebuilt is a silent recording.
        restartCapture(reason: "interruption ended")
    }

    // MARK: - 2. Route change

    func handleRouteLost() {
        guard isRecording, !isPaused else { return }
        pause(.routeLost)
    }

    func noteRouteChanged() {
        guard isRecording else { return }
        NSLog("[Recording] audio route changed; capture continues")
    }

    // MARK: - 3. Media services reset

    func handleMediaServicesReset() {
        guard isRecording else { return }
        // Everything AVFoundation owns is gone. Route through the SAME recovery path the watchdog
        // uses rather than special-casing it: rebuild the engine around a freshly configured
        // session, reusing the existing gate so pause state and pre-roll survive.
        NSLog("[Recording] media services were reset — rebuilding capture")
        restartCapture(reason: "audio services restarted")
    }
}
