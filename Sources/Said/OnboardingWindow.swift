import SaidKit
import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import UserNotifications

/// First-run permission walkthrough: Microphone + Screen Recording (with the quit-and-relaunch note),
/// plus the optional Notifications grant. Sets an "onboarded" flag so it only appears once.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    @Published var screenGranted = false
    @Published var notifyStatus: UNAuthorizationStatus = .notDetermined
    @Published var calendarEnabled = false
    @Published var calendarAuthorized = false
    private var timer: Timer?

    func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        screenGranted = CGPreflightScreenCaptureAccess()
        Task { notifyStatus = await Notifier.authorizationStatus() }
        // Calendar status is only ever queried once the feature is ON (the strict "zero EventKit
        // use while off" invariant — even the static status check is gated).
        calendarEnabled = AppModel.shared.calendarCaptureEnabled
        calendarAuthorized = calendarEnabled ? CalendarMonitor.authorized : false
    }

    /// Turn on calendar-aware capture; AppModel creates the monitor, which lazily requests access.
    func enableCalendar() {
        AppModel.shared.calendarCaptureEnabled = true
        refresh()
    }
    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func requestMic() { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); refresh() } }
    func requestScreen() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        openSettings("Privacy_ScreenCapture")
    }
    func requestNotifications() { Task { _ = await Notifier.requestAuthorization(); refresh() } }
    func openSettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
    func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        WindowManager.shared.closeOnboarding()
    }
}

struct OnboardingWindow: View {
    @StateObject private var m = OnboardingModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Said").font(Theme.ui(18, weight: .semibold))
                Text("Everything runs on this Mac — no cloud, no account. Grant a couple of permissions and you're set.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                OnDeviceBadge().padding(.top, 2)
            }
            .padding(18)
            Divider().overlay(Theme.hairline)

            VStack(spacing: 0) {
                row(icon: "mic", title: "Microphone",
                    detail: "For recording from your mic.",
                    state: micState,
                    action: m.micStatus == .notDetermined ? ("Allow", { m.requestMic() })
                                                          : (m.micStatus == .authorized ? nil : ("Open Settings", { m.openSettings("Privacy_Microphone") })))
                Divider().overlay(Theme.hairline).padding(.leading, 52)
                row(icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                    detail: "Required to capture system audio (and slides). After granting, quit and relaunch Said.",
                    state: m.screenGranted ? .ok : .pending,
                    action: m.screenGranted ? nil : ("Open Settings", { m.requestScreen() }))
                Divider().overlay(Theme.hairline).padding(.leading, 52)
                row(icon: "bell", title: "Notifications (optional)",
                    detail: "A heads-up when a long transcription, summary, or import finishes.",
                    state: notifyState,
                    action: m.notifyStatus == .notDetermined ? ("Allow", { m.requestNotifications() })
                                                            : (m.notifyStatus == .authorized ? nil : ("Open Settings", { m.openSettings("") })))
                Divider().overlay(Theme.hairline).padding(.leading, 52)
                row(icon: "calendar", title: "Calendar (optional)",
                    detail: "Detect upcoming video meetings (Zoom, Teams, Meet…) and offer a bot-free local recording — nothing joins the call, and your calendar is read on-device only.",
                    state: calendarState,
                    action: !m.calendarEnabled ? ("Enable", { m.enableCalendar() })
                                               : (m.calendarAuthorized ? nil : ("Open Settings", { m.openSettings("Privacy_Calendars") })))
            }
            .padding(.vertical, 4)

            Divider().overlay(Theme.hairline)
            HStack {
                Text("You can change these anytime in System Settings.").font(Theme.ui(11)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Get started") { m.finish() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
        .background(Theme.windowBG)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .onAppear { m.startPolling() }
        .onDisappear { m.stopPolling() }
    }

    private enum State { case ok, pending, denied }
    private var micState: State {
        switch m.micStatus { case .authorized: return .ok; case .notDetermined: return .pending; default: return .denied }
    }
    private var notifyState: State {
        switch m.notifyStatus { case .authorized, .provisional: return .ok; case .notDetermined: return .pending; default: return .denied }
    }
    private var calendarState: State {
        m.calendarEnabled && m.calendarAuthorized ? .ok : .pending   // optional — never shown as "Denied"
    }

    @ViewBuilder
    private func row(icon: String, title: String, detail: String, state: State, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Theme.text2).frame(width: 28).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(Theme.ui(13.5, weight: .medium))
                    stateBadge(state)
                }
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.0) { action.1() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder
    private func stateBadge(_ s: State) -> some View {
        switch s {
        case .ok: Label("Granted", systemImage: "checkmark.circle.fill").font(Theme.ui(10.5)).foregroundStyle(Theme.ok)
        case .pending: Text("Needed").font(Theme.ui(10.5)).foregroundStyle(Theme.text3)
        case .denied: Label("Denied", systemImage: "xmark.circle").font(Theme.ui(10.5)).foregroundStyle(Theme.recordText)
        }
    }
}
