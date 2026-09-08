import SwiftUI
import SaidKit

/// The iPhone app.
///
/// Everything below the UI is `SaidKit` — the same session store, capture primitives, transcription,
/// diarization, intelligence and `.said` format the Mac uses. This target adds screens and the two
/// things only a phone has: an `AVAudioSession` to negotiate with, and a camera pointed at a wall.
@main
struct SaidApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppEnvironment.configure()
        return true
    }
}
