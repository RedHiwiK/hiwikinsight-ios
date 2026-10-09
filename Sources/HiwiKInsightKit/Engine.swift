import Foundation
import os

/// Session state is persisted to UserDefaults so that if the app is killed in the background,
/// the next launch can still emit `session.ended` for the previous session.
struct SessionState: Codable, Equatable {
    var id: String
    var startedAt: Date
    /// Accumulated foreground seconds (excluding the current foreground stretch).
    var foregroundSeconds: TimeInterval
    /// Start of the current foreground stretch; nil while in the background.
    var activeSince: Date?
    var lastBackground: Date?
    /// Time of the most recently recorded event. Used to approximate the session end when the
    /// process is killed in the foreground (crash / force quit).
    var lastActivity: Date?
}

/// All state and I/O are serialized on this actor.
actor Engine {
    private let config: HiwiKInsightConfiguration
    private let queue: EventQueue
    private let transport: Transport
    private nonisolated(unsafe) let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "HiwiKInsight", category: "engine")

    nonisolated let installID: String
    private(set) var session: SessionState?
    private var context: [String: String]
    private var enabled = true

    /// `session.started` is deferred so the app can report the launch source (widget / notification).
    private var pendingSessionStart: (id: String, at: Date)?
    private var pendingSource: String?
    /// After the install id is first generated, `app.installed` waits for the AppTransaction result.
    private var pendingInstall = false
    /// When the environment can only be inferred from the fallback (Release build that has never
    /// obtained an AppTransaction on this device), hold sending until AppTransaction resolves:
    /// otherwise a TestFlight build would fall back to `production` and pollute production data.
    private var awaitingEnvironment = false
    /// A backfill of the original download date is in flight; prevents concurrent requests on repeated foregrounding.
    private var acquisitionInFlight = false

    private var flushing = false
    private var retryAt: Date?
    private var backoffStep = 0
    private static let backoff: [TimeInterval] = [30, 120, 600, 3600]

    // Persisted UserDefaults keys. They intentionally keep the original "hiwik_insight." prefix
    // (pre-0.2.0 spelling) so existing installs keep their install_id and session state after
    // upgrading to the renamed SDK. Do not change them.
    private enum Key {
        static let installID = "hiwik_insight.install_id"
        static let session = "hiwik_insight.session"
        static let lastVersion = "hiwik_insight.last_version"
        static let lastSnapshotDay = "hiwik_insight.last_snapshot_day"
        /// Environment from the most recent AppTransaction; reused when it later cannot be obtained.
        static let environment = "hiwik_insight.env"
        /// `app.installed` was sent without an original download date; `app.acquired` is sent later.
        static let acquisitionPending = "hiwik_insight.acquisition_pending"
    }

    init(
        config: HiwiKInsightConfiguration,
        storageDirectory: URL,
        defaultsSuiteName: String?,
        transport: Transport,
        context: [String: String],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.queue = EventQueue(directory: storageDirectory, capacity: config.maxQueuedEvents)
        self.transport = transport
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        var context = context
        // The xcode environment is determined at compile time and is never wrong; any other fallback
        // value is overridden by the most recent AppTransaction result on this device.
        if context["env"] != "xcode" {
            if let cached = defaults.string(forKey: Key.environment) {
                context["env"] = cached
            } else if context["env"] != nil {
                awaitingEnvironment = true
            }
        }
        self.context = context
        self.now = now

        if let id = defaults.string(forKey: Key.installID) {
            installID = id
        } else {
            installID = UUID().uuidString.lowercased()
            defaults.set(installID, forKey: Key.installID)
            pendingInstall = true
        }
        if let data = defaults.data(forKey: Key.session),
           var s = try? JSONDecoder().decode(SessionState.self, from: data) {
            // The previous process ended in the foreground (no did-enter-background notification):
            // mark it as backgrounded at the last activity time, otherwise didBecomeActive would
            // think we are still in the foreground and never start a new session.
            if let since = s.activeSince {
                let end = max(since, s.lastActivity ?? since)
                s.foregroundSeconds += end.timeIntervalSince(since)
                s.activeSince = nil
                s.lastBackground = end
                if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Key.session) }
            }
            session = s
        }
    }

    // MARK: - Launch

    /// Called once at launch: detects version changes. `app.installed` is sent by `resolveInstall`
    /// once the download date is known.
    func bootstrap(appVersion: String?) {
        let last = defaults.string(forKey: Key.lastVersion)
        if let appVersion, last != appVersion {
            if let last, !pendingInstall {
                record("app.updated", ["from": last, "to": appVersion])
            }
            defaults.set(appVersion, forKey: Key.lastVersion)
        }
    }

    func resolveInstall(originalDownload: Date?, status: String? = nil) {
        guard pendingInstall else { return }
        pendingInstall = false
        var params: [String: String] = [:]
        if let originalDownload { params["original_download_ts"] = String(originalDownload.millis) }
        if let status { params["at_status"] = status }
        if config.hasPriorUsage { params["prior_usage"] = "1" }
        record("app.installed", params)
        // StoreKit is often not ready on first launch (error: unknown); retry on each new session
        // and send app.acquired once the date is available.
        if originalDownload == nil, status != "skipped" {
            defaults.set(true, forKey: Key.acquisitionPending)
        }
    }

    /// Environment from AppTransaction: update the context and remember it for when it later cannot
    /// be obtained. Releases any held sending whether or not it succeeded.
    func resolveEnvironment(_ env: String?) {
        if let env {
            context["env"] = env
            defaults.set(env, forKey: Key.environment)
        }
        guard awaitingEnvironment else { return }
        awaitingEnvironment = false
        Task { await self.flush() }
    }

    /// Whether the original download date still needs to be backfilled. When this returns true the
    /// caller must fetch AppTransaction and call `resolveAcquisition`.
    func claimAcquisitionAttempt() -> Bool {
        guard enabled, !acquisitionInFlight, defaults.bool(forKey: Key.acquisitionPending) else { return false }
        acquisitionInFlight = true
        return true
    }

    func resolveAcquisition(originalDownload: Date?, status: String) {
        acquisitionInFlight = false
        guard let originalDownload, defaults.bool(forKey: Key.acquisitionPending) else { return }
        defaults.removeObject(forKey: Key.acquisitionPending)
        record("app.acquired", ["original_download_ts": String(originalDownload.millis), "at_status": status])
    }

    func updateContext(_ values: [String: String]) {
        context.merge(values) { _, new in new }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            queue.removeAll()
            pendingSessionStart = nil
        }
    }

    // MARK: - Events

    func record(_ name: String, _ params: [String: String] = [:], at date: Date? = nil) {
        guard enabled else { return }
        let event = QueuedEvent(
            id: UUID().uuidString.lowercased(),
            name: name,
            ts: (date ?? now()).millis,
            session: session?.id,
            params: Limits.sanitize(params)
        )
        queue.append(event)
        if var s = session, s.activeSince != nil {
            s.lastActivity = Date(timeIntervalSince1970: TimeInterval(event.ts) / 1000)
            setSession(s)
        }
        if config.debugLogging { logger.debug("\(name, privacy: .public) \(params, privacy: .public)") }
        if queue.count >= config.flushThreshold {
            Task { await self.flush() }
        }
    }

    // MARK: - Sessions

    /// Returns true if a new session was started.
    @discardableResult
    func didBecomeActive() -> Bool {
        let t = now()
        if var s = session, s.activeSince == nil, let bg = s.lastBackground,
           t.timeIntervalSince(bg) < config.sessionTimeout {
            s.activeSince = t
            s.lastBackground = nil
            setSession(s)
            return false
        }
        if session?.activeSince != nil { return false }  // Already in the foreground (duplicate notification).

        if let old = session {
            let end = old.lastBackground ?? t
            record("session.ended", ["duration_s": String(Int(old.foregroundSeconds.rounded()))], at: end)
        }
        let s = SessionState(id: UUID().uuidString.lowercased(), startedAt: t, foregroundSeconds: 0, activeSince: t)
        setSession(s)
        pendingSessionStart = (s.id, t)
        pendingSource = nil
        if config.launchSourceWindow <= 0 {
            emitPendingSessionStart()
        } else {
            let window = config.launchSourceWindow
            Task {
                try? await Task.sleep(for: .seconds(window))
                self.emitPendingSessionStart()
            }
        }
        return true
    }

    func didEnterBackground() {
        emitPendingSessionStart()
        guard var s = session, let since = s.activeSince else { return }
        let t = now()
        s.foregroundSeconds += max(0, t.timeIntervalSince(since))
        s.activeSince = nil
        s.lastBackground = t
        setSession(s)
    }

    /// Called when the app is opened from an external entry point such as a widget or notification.
    func setLaunchSource(_ source: String) {
        if pendingSessionStart != nil {
            pendingSource = source
        } else {
            record("app.opened", ["source": source])
        }
    }

    func emitPendingSessionStart() {
        guard let pending = pendingSessionStart, pending.id == session?.id else {
            pendingSessionStart = nil
            return
        }
        pendingSessionStart = nil
        record("session.started", ["source": pendingSource ?? "icon"], at: pending.at)
        pendingSource = nil
    }

    /// Whether no snapshot has been sent yet for the current local calendar day. When this returns
    /// true the caller must send `user.snapshot`.
    func claimDailySnapshot(calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        guard defaults.string(forKey: Key.lastSnapshotDay) != day else { return false }
        defaults.set(day, forKey: Key.lastSnapshotDay)
        return true
    }

    private func setSession(_ s: SessionState) {
        session = s
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Key.session) }
    }

    // MARK: - Sending

    func flush() async {
        guard enabled, !awaitingEnvironment, !flushing, !queue.isEmpty else { return }
        if let retryAt, now() < retryAt { return }
        flushing = true
        defer { flushing = false }

        while !queue.isEmpty {
            let events = queue.peek(Limits.batchSize)
            let batch = Batch(app: config.appKey, installID: installID, sentAt: now().millis,
                              context: context, events: events)
            guard let body = try? JSONEncoder().encode(batch) else {
                queue.remove(ids: Set(events.map(\.id)))
                continue
            }
            let result = await transport.send(body)
            switch result {
            case .accepted:
                queue.remove(ids: Set(events.map(\.id)))
                backoffStep = 0
                retryAt = nil
            case .rejected(let status):
                logger.error("batch rejected: \(status)")
                queue.remove(ids: Set(events.map(\.id)))
            case .retry:
                retryAt = now().addingTimeInterval(Self.backoff[min(backoffStep, Self.backoff.count - 1)])
                backoffStep += 1
                return
            }
        }
    }

    var queuedEvents: [QueuedEvent] { queue.events }
}
