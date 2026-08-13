import SaidKit
import SwiftUI
import AppKit

// MARK: - The main menu
//
// v3, screen 01D: "There is a menu bar. v2 had none. File ▸ Import, Session ▸ Add Bookmark,
// View ▸ Verbatim/Cleaned/Redacted — every action reachable, scriptable, and searchable in Help."
//
// Every item here calls the same model method its button does, so the menu adds discoverability
// without adding a second code path. The four capture actions carry the SAME key equivalents as the
// global Carbon hotkeys; both routes funnel through `AppModel.fireOnce` so one press does one thing.

struct SaidCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var shell = ShellModel.shared

    private var viewer: SessionViewerModel? { shell.viewer }

    var body: some Commands {
        // ⌘, — where every Mac user looks for settings.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WindowManager.shared.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // "New" means "start recording" in this app.
        CommandGroup(replacing: .newItem) {
            Button(model.isRecording ? "Stop Recording" : "Start Recording") {
                model.fireOnce("toggle") { model.toggle() }
            }
            .keyboardShortcut("t", modifiers: [.option, .command])
            .disabled(model.status.isBusyPreparing)

            Divider()

            Button("Import Audio or Video…") { model.presentImportPanel() }
                .keyboardShortcut("i", modifiers: [.shift, .command])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export…") { exportCurrent() }
                .keyboardShortcut("e", modifiers: [.shift, .command])
                .disabled(viewer == nil && !model.canExport)

            Button("Reveal in Finder") { revealCurrent() }
                .keyboardShortcut("r", modifiers: [.shift, .command])

            Divider()

            Button("Open Transcripts Folder") { model.openTranscriptsFolder() }
        }

        // Find lives in the Edit menu, where ⌘F belongs on a Mac.
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { NotificationCenter.default.post(name: .transcriberShowFindBar, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(viewer == nil)
        }

        CommandMenu("Session") {
            Button(model.isPaused ? "Resume Recording" : "Pause Recording") {
                model.fireOnce("pause") { model.togglePause() }
            }
            .keyboardShortcut("p", modifiers: [.option, .command])
            .disabled(!model.isRecording)

            Button("Add Bookmark") { model.fireOnce("bookmark") { model.addBookmark() } }
                .keyboardShortcut("b", modifiers: [.option, .command])
                .disabled(!model.isRecording)

            Button(model.isRecording ? "Stop Recording" : "Record Screen…") {
                model.fireOnce("screen") { model.toggleScreenRecording() }
            }
            .keyboardShortcut("s", modifiers: [.option, .command])
            .disabled(model.status.isBusyPreparing)

            Divider()

            Button("Summarize") { model.summarizeTranscript() }
                .disabled(model.transcript.isEmpty || model.isSummarizing)

            Button("Ask Your Sessions…") { WindowManager.shared.showAsk() }
        }

        CommandGroup(before: .toolbar) {
            // v3 screen 02: the transcript's three views, reachable from the menu bar.
            Button("Verbatim") { setViewMode(cleaned: false, redacted: false) }
                .keyboardShortcut("1", modifiers: [.control, .command])
                .disabled(viewer == nil)
            Button("Cleaned") { setViewMode(cleaned: true, redacted: false) }
                .keyboardShortcut("2", modifiers: [.control, .command])
                .disabled(viewer?.hasCleaned != true)
            Button("Redacted") { setViewMode(cleaned: false, redacted: true) }
                .keyboardShortcut("3", modifiers: [.control, .command])
                .disabled(viewer?.hasRedacted != true)

            Divider()

            Button(shell.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                shell.inspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])

            Button("Back to Library") { shell.closeSession() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!shell.route.isSession)

            Divider()

            ForEach(LibraryCollection.allCases) { c in
                Button(c.label) {
                    shell.library.collection = c
                    shell.library.selectedTag = nil
                    shell.go(.library)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(c.shortcutIndex)")), modifiers: .command)
            }

            Divider()
        }

        CommandGroup(before: .windowList) {
            Button("Said") { WindowManager.shared.showMain(.library) }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("Said Help") {
                // Everything is on-device, so "help" is the app's own surfaces, not a web page.
                WindowManager.shared.showSettings()
            }
        }
    }

    // MARK: Actions

    private func setViewMode(cleaned: Bool, redacted: Bool) {
        guard let viewer else { return }
        viewer.showRedacted = redacted
        viewer.showCleaned = cleaned
    }

    private func exportCurrent() {
        if let viewer { viewer.exportText() } else if model.canExport { model.exportHTML() }
    }

    private func revealCurrent() {
        if let viewer { viewer.revealInFinder() }
        else if let dir = ShellModel.shared.selectedSession?.dir { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
        else { model.openTranscriptsFolder() }
    }
}

extension Notification.Name {
    /// Posted by Edit ▸ Find (⌘F); the open session's transcript reveals its find bar.
    static let transcriberShowFindBar = Notification.Name("transcriberShowFindBar")
}
