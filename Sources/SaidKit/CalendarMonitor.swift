import Foundation
import EventKit

// MARK: - Pure value types + logic (testable without EventKit — `--selftest-calendar`)

/// A detected meeting occurrence.
public struct MeetingCandidate: Sendable, Equatable {
    var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var url: URL?
}

public enum MeetingTriggerAction: Sendable, Equatable { case prompt, autoStart, ignore }

/// Pure meeting-link detection. Strong provider patterns are searched across the URL field,
/// location, and notes; a generic `https://` URL in the URL FIELD only is a weak fallback.
public enum MeetingLinkDetector {

    private static let strongPatterns: [String] = [
        #"https?://[^\s<>"']*zoom\.us/j/[^\s<>"']+"#,
        #"https?://[^\s<>"']*zoom\.us/my/[^\s<>"']+"#,
        #"https?://teams\.microsoft\.com/l/meetup-join[^\s<>"']*"#,
        #"https?://teams\.live\.com/[^\s<>"']+"#,
        #"https?://meet\.google\.com/[^\s<>"']+"#,
        #"https?://[^\s<>"']*\.webex\.com/(meet|join)[^\s<>"']*"#,
        #"https?://whereby\.com/[^\s<>"']+"#,
    ]

    public static func videoMeetingURL(urlField: String?, notes: String?, location: String?) -> URL? {
        // Strong matches first, in field-priority order (URL field, then location, then notes).
        for field in [urlField, location, notes] {
            guard let field, !field.isEmpty else { continue }
            for pattern in strongPatterns {
                if let r = field.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                   let url = URL(string: String(field[r])) {
                    return url
                }
            }
        }
        // Weak fallback: any https URL, but ONLY from the dedicated URL field (notes/location
        // links like agenda docs must not make every event look like a video meeting).
        if let urlField,
           let r = urlField.range(of: #"https://[^\s<>"']+"#, options: .regularExpression),
           let url = URL(string: String(urlField[r])) {
            return url
        }
        return nil
    }
}

/// Pure trigger decision. Rules: only events with a detected link fire; never while already
/// recording; each event fires at most once; fire from `leadSeconds` before start until the event
/// ends (so a meeting already in progress at toggle-on also fires).
public enum MeetingTriggerLogic {
    public static func decide(now: Date, start: Date, end: Date, leadSeconds: TimeInterval,
                       hasLink: Bool, isRecording: Bool, alreadyFired: Bool,
                       autoStart: Bool) -> MeetingTriggerAction {
        guard hasLink, !isRecording, !alreadyFired else { return .ignore }
        guard now >= start.addingTimeInterval(-leadSeconds), now < end else { return .ignore }
        return autoStart ? .autoStart : .prompt
    }
}

// MARK: - EventKit monitor

/// Watches the LOCAL calendar store for upcoming/active video meetings (Feature C). Instantiated
/// ONLY while "Calendar-aware capture" is enabled — when the toggle is off this type (and thus
/// any `EKEventStore`) simply never exists, and no permission prompt can appear. Reads stay
/// on-device; nothing is sent anywhere. Access is requested lazily on `start()`; a denied grant
/// makes the monitor silently inert (same contract as Notifications).
@MainActor
public final class CalendarMonitor {

    private let leadSeconds: () -> TimeInterval
    private let autoStart: () -> Bool
    private let isRecording: () -> Bool
    private let onTrigger: (MeetingCandidate, MeetingTriggerAction) -> Void

    private var store: EKEventStore?
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var firedEventIDs = Set<String>()   // "fire once" per event occurrence (per app run)

    public init(leadSeconds: @escaping () -> TimeInterval,
         autoStart: @escaping () -> Bool,
         isRecording: @escaping () -> Bool,
         onTrigger: @escaping (MeetingCandidate, MeetingTriggerAction) -> Void) {
        self.leadSeconds = leadSeconds
        self.autoStart = autoStart
        self.isRecording = isRecording
        self.onTrigger = onTrigger
    }

    public func start() {
        requestAccessIfNeeded()
        // Lightweight scheduler: a 60 s tick plus re-evaluation whenever the calendar DB changes.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarMonitor.activeInstance?.evaluate() }
        }
        CalendarMonitor.activeInstance = self
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in CalendarMonitor.activeInstance?.evaluate() }
        }
        evaluate()
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        if let o = changeObserver { NotificationCenter.default.removeObserver(o); changeObserver = nil }
        if CalendarMonitor.activeInstance === self { CalendarMonitor.activeInstance = nil }
        store = nil
    }

    /// Request full calendar access if the user hasn't decided yet (macOS 14+ API — the package's
    /// platform floor). Denied → the monitor stays silently inert; re-enabling the feature
    /// re-prompts only while the status is still notDetermined (OS behavior).
    public func requestAccessIfNeeded() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .notDetermined else { return }
        ensureStore().requestFullAccessToEvents { _, _ in
            Task { @MainActor in CalendarMonitor.activeInstance?.evaluate() }
        }
    }

    public static var authorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    // MARK: - Internals

    /// Weak-ish global so timer/notification closures can't retain a stopped monitor.
    private static weak var activeInstance: CalendarMonitor?

    private func ensureStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    private func evaluate() {
        guard Self.authorized else { return }   // denied/undecided → silently inert
        let store = ensureStore()
        let now = Date()
        let lead = leadSeconds()
        // Look back a few hours so an in-progress meeting (started before toggle-on) still fires,
        // and forward past the lead window.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-4 * 3600),
                                                 end: now.addingTimeInterval(lead + 120),
                                                 calendars: nil)
        for event in store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate }) {
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate else { continue }
            let link = MeetingLinkDetector.videoMeetingURL(urlField: event.url?.absoluteString,
                                                           notes: event.notes,
                                                           location: event.location)
            let id = "\(event.eventIdentifier ?? event.title ?? "?")@\(start.timeIntervalSince1970)"
            let action = MeetingTriggerLogic.decide(now: now, start: start, end: end,
                                                    leadSeconds: lead, hasLink: link != nil,
                                                    isRecording: isRecording(),
                                                    alreadyFired: firedEventIDs.contains(id),
                                                    autoStart: autoStart())
            guard action != .ignore else { continue }
            firedEventIDs.insert(id)
            onTrigger(MeetingCandidate(id: id, title: event.title ?? "Meeting",
                                       start: start, end: end, url: link), action)
            break   // at most one trigger per tick
        }
    }
}
