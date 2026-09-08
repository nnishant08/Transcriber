import Foundation
import SaidKit

/// Persisted settings, in `UserDefaults`, following the Mac's pattern (same keys where the meaning
/// is the same, so behaviour is comparable across platforms).
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let d = UserDefaults.standard

    private init() {
        model = d.string(forKey: "whisperModel") ?? "openai_whisper-base.en"
        language = d.string(forKey: "transcriptionLanguage") ?? "en"
        autoPauseEnabled = (d.object(forKey: "autoPauseEnabled") as? Bool) ?? true
        autoPauseSeconds = (d.object(forKey: "autoPauseSeconds") as? Double) ?? AudioActivity.defaultAutoPauseSeconds
        diarizationEnabled = d.bool(forKey: "diarizationEnabled")
        cleanupEnabled = d.bool(forKey: "cleanupEnabled")
        allowBluetooth = d.bool(forKey: "allowBluetoothInput")
        customVocabulary = d.stringArray(forKey: "customVocabulary") ?? []
        AudioCaptureMic.allowsBluetoothInput = allowBluetooth
    }

    @Published var model: String { didSet { d.set(model, forKey: "whisperModel") } }
    @Published var language: String { didSet { d.set(language, forKey: "transcriptionLanguage") } }
    @Published var autoPauseEnabled: Bool { didSet { d.set(autoPauseEnabled, forKey: "autoPauseEnabled") } }
    @Published var autoPauseSeconds: Double { didSet { d.set(autoPauseSeconds, forKey: "autoPauseSeconds") } }
    @Published var diarizationEnabled: Bool { didSet { d.set(diarizationEnabled, forKey: "diarizationEnabled") } }
    @Published var cleanupEnabled: Bool { didSet { d.set(cleanupEnabled, forKey: "cleanupEnabled") } }
    @Published var customVocabulary: [String] { didSet { d.set(customVocabulary, forKey: "customVocabulary") } }

    /// OFF by default, and the UI states the cost: routing the mic over Bluetooth drops it to a
    /// narrowband mono HFP link that is audibly worse than the built-in mic.
    @Published var allowBluetooth: Bool {
        didSet {
            d.set(allowBluetooth, forKey: "allowBluetoothInput")
            AudioCaptureMic.allowsBluetoothInput = allowBluetooth
        }
    }

    /// Models above this need headroom the smallest supported devices do not have. Presented to the
    /// user as accuracy-versus-battery, never as model names.
    var availableModels: [(id: String, label: String, detail: String)] {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var out: [(String, String, String)] = [
            ("openai_whisper-base.en", "Faster", "Keeps up easily. Lightest on battery."),
            ("openai_whisper-small.en", "Balanced", "More accurate. Noticeably more battery."),
        ]
        // large-v3-turbo is ~1.5 GB resident. Offering it on a 4 GB device invites a jetsam
        // mid-recording, which is the one failure this app must never have.
        if gb >= 7.5 {
            out.append(("openai_whisper-large-v3_turbo", "Most accurate",
                        "Best with accents and noise. Heaviest on battery."))
        }
        return out.map { (id: $0.0, label: $0.1, detail: $0.2) }
    }
}
