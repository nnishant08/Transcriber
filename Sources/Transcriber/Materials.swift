import SwiftUI
import AppKit
import Combine

// MARK: - Real AppKit materials
//
// SwiftUI's `.ultraThinMaterial` is a blur, not a *sidebar*. A Mac window reads as native largely
// because its sidebar is an `NSVisualEffectView` with the `.sidebar` material: it picks up the
// desktop behind the window, dims when the window loses key, and — the reason it matters here —
// draws itself opaque when the user turns on Reduce Transparency. We get all three for free by
// hosting the real view instead of approximating it.

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// `.followsWindowActiveState` is what makes a sidebar dim with the window, like Finder's.
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
    }
}

extension View {
    /// Sidebar vibrancy with an opaque fallback painted underneath, so the pane is never
    /// transparent-to-nothing while the effect view resolves.
    func sidebarMaterial() -> some View {
        background(Theme.sidebarBG).background(VisualEffect(material: .sidebar))
    }
    /// Toolbar / header strip material.
    func headerMaterial() -> some View {
        background(Theme.titlebar).background(VisualEffect(material: .headerView))
    }
    /// Floating panels and popovers (HUD material — v3's blurred capture panel).
    func panelMaterial() -> some View {
        background(VisualEffect(material: .popover, blending: .behindWindow))
    }
}

// MARK: - Accessibility display options
//
// v3, screen 03D: "Every accessibility setting has a state. Drawn, not assumed." Reduce Motion is
// available to SwiftUI as an environment value; Reduce Transparency and Increase Contrast are not,
// so this publishes them. `NSVisualEffectView` already handles Reduce Transparency by itself — this
// exists for the fills, blurs and shadows we draw by hand.

@MainActor
final class DisplayOptions: ObservableObject {
    static let shared = DisplayOptions()

    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool

    private var observer: NSObjectProtocol?

    private init() {
        let ws = NSWorkspace.shared
        reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
        observer = ws.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                self.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
        }
    }

    /// Hairline weight: Increase Contrast asks for a border you can actually see.
    var borderWidth: CGFloat { increaseContrast ? 1.5 : 1 }
    /// Drop shadows read as haze under Increase Contrast; trade them for a solid border.
    var shadowRadius: CGFloat { increaseContrast ? 0 : 1 }
}

private struct DisplayOptionsKey: EnvironmentKey {
    @MainActor static var defaultValue: DisplayOptions { .shared }
}

extension EnvironmentValues {
    var displayOptions: DisplayOptions {
        get { self[DisplayOptionsKey.self] }
        set { self[DisplayOptionsKey.self] = newValue }
    }
}
