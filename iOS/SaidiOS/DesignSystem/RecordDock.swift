import SwiftUI
import SaidKit

/// The root navigation: Library on the left, the record blob in the middle, Ask on the right.
///
/// A dock, not a tab bar. Ask occupies the right third — the placement the Mac redesign left open
/// and the iPhone screens settled (see CLAUDE.md ▸ Design system).
struct RecordDock: View {
    enum Tab { case library, ask }

    @Binding var tab: Tab
    var onRecord: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            HStack {
                dockTab(.library, label: "Library", systemImage: "square.stack.3d.up.fill")
                Spacer(minLength: 0)
                dockTab(.ask, label: "Ask", systemImage: "sparkle.magnifyingglass")
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(Palette.ink)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            recordButton
                .offset(y: -26)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    /// The record button IS the app icon's mark at 70pt — the same drawing, not a separate asset.
    private var recordButton: some View {
        Button(action: onRecord) {
            BlobPair(size: 19)
                .frame(width: 70, height: 70)
                .background(Palette.violet)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.windowBG, lineWidth: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record")
        .accessibilityHint("Starts a new recording")
        .accessibilityAddTraits(.isButton)
    }

    private func dockTab(_ which: Tab, label: String, systemImage: String) -> some View {
        Button { tab = which } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(label)
                    .font(Theme.ui(10, weight: tab == which ? .bold : .semibold))
            }
            .foregroundStyle(tab == which ? Color.white : Color.white.opacity(0.6))
            .frame(width: 62)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(tab == which ? [.isButton, .isSelected] : .isButton)
    }
}
