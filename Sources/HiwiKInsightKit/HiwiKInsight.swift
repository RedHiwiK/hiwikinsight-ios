import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Entry point of the HiwiKInsight SDK.
///
/// ```swift
/// HiwiKInsight.start(.init(appKey: "pawprint", endpoint: URL(string: "https://insight.example.com")!))
/// HiwiKInsight.signal("entry.created", ["entry_type": "note"])
/// ```
///
/// Except for `start`, every method may be called from any thread and returns immediately.
public enum HiwiKInsight {
    private static let box = EngineBox()

    // MARK: - Launch

    /// Call once at app launch (repeated calls are ignored).
    /// `snapshot` is invoked on the first session of each local calendar day; the bucketed
    /// attributes it returns are sent as `user.snapshot`.
    @MainActor
    public static func start(
        _ config: HiwiKInsightConfiguration,
        snapshot: (@MainActor () async -> [String: String])? = nil
    ) {
        guard box.engine == nil else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Keeps the pre-0.2.0 "HiwikInsight" folder name so queued events of existing installs
            // survive the rename. Do not change it.
            .appendingPathComponent("HiwikInsight/\(config.appKey)", isDirectory: true)
        var context = DeviceInfo.staticContext()
        context.merge(DeviceInfo.dynamicContext()) { _, new in new }
        let engine = Engine(config: config, storageDirectory: dir, defaultsSuiteName: config.defaultsSuiteName,
                            transport: HTTPTransport(endpoint: config.endpoint), context: context)
        box.engine = engine
        box.snapshot = snapshot

        let appVersion = context["app_version"]
        Task {
            await engine.bootstrap(appVersion: appVersion)
            let at = await DeviceInfo.appTransaction()
            await engine.resolveEnvironment(at.env)
            await engine.resolveInstall(originalDownload: at.originalDownload, status: at.status)
            if let storefront = await DeviceInfo.storefront() {
                await engine.updateContext(["storefront": storefront])
            }
        }

        // Periodic flush.
        let interval = config.flushInterval
        Task.detached(priority: .utility) {
            while true {
                try? await Task.sleep(for: .seconds(interval))
                await engine.flush()
            }
        }

        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handleDidBecomeActive() }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handleDidEnterBackground() }
        }
        // `start` may be called after the app is already active (e.g. from `.task`); catch up once.
        if UIApplication.shared.applicationState == .active {
            handleDidBecomeActive()
        }
        #endif
    }

    // MARK: - Events

    public static func signal(_ name: String, _ params: [String: String] = [:]) {
        guard let engine = box.engine else { return }
        let at = Date()
        Task { await engine.record(name, params, at: at) }
    }

    public static func error(id: String, category: String, message: String? = nil) {
        var params = ["id": id, "category": category]
        params["message"] = message
        signal("error", params)
    }

    /// Call before starting a purchase: records `purchase.started` and returns a UUID to pass as the
    /// StoreKit `appAccountToken`. The event is flushed immediately so the server can attribute the
    /// purchase when the App Store Server Notification arrives.
    public static func beginPurchase(product: String, context: String) -> UUID {
        let token = UUID()
        guard let engine = box.engine else { return token }
        let at = Date()
        Task {
            await engine.record("purchase.started",
                                ["product": product, "context": context, "token": token.uuidString.lowercased()],
                                at: at)
            await engine.flush()
        }
        return token
    }

    /// Call when the app is opened from an external entry point such as a Home Screen widget or a
    /// notification, e.g. `widget_today`, `notification_reminder`. If called shortly after a new
    /// session starts, it becomes the `source` of `session.started`; otherwise an `app.opened`
    /// event is recorded.
    public static func setLaunchSource(_ source: String) {
        guard let engine = box.engine else { return }
        Task { await engine.setLaunchSource(source) }
    }

    // MARK: - Screens

    public static func screenViewed(_ screen: String, module: String, _ params: [String: String] = [:]) {
        var p = params
        p["screen"] = screen
        p["module"] = module
        signal("screen.viewed", p)
    }

    public static func screenLeft(_ screen: String, module: String, duration: TimeInterval) {
        signal("screen.left", ["screen": screen, "module": module,
                               "duration_s": String(Int(max(0, duration).rounded()))])
    }

    // MARK: - Privacy

    /// When disabled, stops collecting and clears unsent events.
    public static func setEnabled(_ enabled: Bool) {
        guard let engine = box.engine else { return }
        Task { await engine.setEnabled(enabled) }
    }

    /// Anonymous install id (for debugging).
    public static var installID: String? {
        get { box.engine?.installID }
    }

    /// Flushes the queue immediately (for debugging or critical moments).
    public static func flush() async {
        await box.engine?.flush()
    }

    // MARK: - Lifecycle

    #if canImport(UIKit)
    @MainActor
    private static func handleDidBecomeActive() {
        guard let engine = box.engine else { return }
        let dynamic = DeviceInfo.dynamicContext()
        let snapshot = box.snapshot
        Task { @MainActor in
            await engine.updateContext(dynamic)
            let newSession = await engine.didBecomeActive()
            if newSession, await engine.claimAcquisitionAttempt() {
                Task {
                    let at = await DeviceInfo.appTransaction()
                    await engine.resolveEnvironment(at.env)
                    await engine.resolveAcquisition(originalDownload: at.originalDownload, status: at.status)
                }
            }
            if let snapshot, await engine.claimDailySnapshot() {
                let values = await snapshot()
                await engine.record("user.snapshot", values)
            }
        }
    }

    @MainActor
    private static func handleDidEnterBackground() {
        guard let engine = box.engine else { return }
        let app = UIApplication.shared
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = app.beginBackgroundTask(withName: "HiwiKInsight.flush") {
            app.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task { @MainActor in
            await engine.didEnterBackground()
            await engine.flush()
            if taskID != .invalid {
                app.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
    }
    #endif
}

/// Holds the global Engine; read-only after `start`.
private final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _engine: Engine?
    private var _snapshot: (@MainActor () async -> [String: String])?

    var engine: Engine? {
        get { lock.withLock { _engine } }
        set { lock.withLock { _engine = newValue } }
    }

    var snapshot: (@MainActor () async -> [String: String])? {
        get { lock.withLock { _snapshot } }
        set { lock.withLock { _snapshot = newValue } }
    }
}
