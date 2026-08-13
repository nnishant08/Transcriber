import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global toggle for Start/Stop. Default: ⌥⌘T. User-configurable in Settings.
    static let toggleRecording = Self("toggleRecording", default: .init(.t, modifiers: [.command, .option]))

    /// Pause / resume the recording in place (the session stays open). Default: ⌥⌘P.
    /// User-configurable in Settings.
    static let togglePause = Self("togglePause", default: .init(.p, modifiers: [.command, .option]))

    /// Start a screen recording (screen + audio in one session), or stop the session in progress.
    /// Default: ⌥⌘S. User-configurable in Settings.
    static let toggleScreenRecording = Self("toggleScreenRecording", default: .init(.s, modifiers: [.command, .option]))

    /// Drop a bookmark at the current moment while recording. Carbon hotkey → no permission.
    /// Default: ⌥⌘B. User-configurable in Settings.
    static let addBookmark = Self("addBookmark", default: .init(.b, modifiers: [.command, .option]))
}
