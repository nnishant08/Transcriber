import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global toggle for Start/Stop. Default: ⌥⌘T. User-configurable in Settings.
    static let toggleRecording = Self("toggleRecording", default: .init(.t, modifiers: [.command, .option]))

    /// Manual grab of the current visual frame — always live while recording with visual capture on.
    /// Default: ⌥⌘S. User-configurable in Settings.
    static let grabFrame = Self("grabFrame", default: .init(.s, modifiers: [.command, .option]))

    /// Drop a bookmark at the current moment while recording. Carbon hotkey → no permission.
    /// Default: ⌥⌘B. User-configurable in Settings.
    static let addBookmark = Self("addBookmark", default: .init(.b, modifiers: [.command, .option]))
}
