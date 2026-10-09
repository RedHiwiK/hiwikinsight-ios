import Foundation
import Testing
@testable import HiwiKInsightKit

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

actor FakeTransport: Transport {
    var results: [SendResult] = []
    private(set) var bodies: [Data] = []
    func set(_ r: [SendResult]) { results = r }
    func send(_ body: Data) async -> SendResult {
        bodies.append(body)
        return results.isEmpty ? .accepted : results.removeFirst()
    }
}

struct Fixture {
    let engine: Engine
    let clock: Clock
    let transport: FakeTransport
    let suite: String
    let dir: URL

    init(clock: Clock = Clock(), suite: String? = nil, dir: URL? = nil, priorUsage: Bool = false,
         context: [String: String] = ["os": "iOS"]) {
        self.suite = suite ?? "insight-test-\(UUID().uuidString)"
        self.dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.clock = clock
        transport = FakeTransport()
        var config = HiwiKInsightConfiguration(appKey: "test", endpoint: URL(string: "https://example.com")!)
        config.launchSourceWindow = 0
        config.flushThreshold = 1000
        config.hasPriorUsage = priorUsage
        engine = Engine(config: config, storageDirectory: self.dir, defaultsSuiteName: self.suite,
                        transport: transport, context: context, now: { [clock] in clock.now })
    }

    func names() async -> [String] { await engine.queuedEvents.map(\.name) }
}

@Suite struct EngineTests {
    @Test func installAndUpdateEvents() async {
        let f = Fixture()
        await f.engine.bootstrap(appVersion: "1.0")
        await f.engine.resolveInstall(originalDownload: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(await f.names() == ["app.installed"])
        #expect(await f.engine.queuedEvents[0].params["original_download_ts"] == "1700000000000")

        // Relaunch with the same defaults after a version upgrade.
        let again = Fixture(clock: f.clock, suite: f.suite, dir: f.dir)
        await again.engine.bootstrap(appVersion: "1.1")
        await again.engine.resolveInstall(originalDownload: nil)
        #expect(await again.names() == ["app.installed", "app.updated"])
        #expect(again.engine.installID == f.engine.installID)
    }

    @Test func installCarriesStatusAndPriorUsage() async {
        let f = Fixture(priorUsage: true)
        await f.engine.bootstrap(appVersion: "1.2.0")
        await f.engine.resolveInstall(originalDownload: nil, status: "error: StoreKitError.unknown")
        let params = await f.engine.queuedEvents[0].params
        #expect(params["prior_usage"] == "1")
        #expect(params["at_status"] == "error: StoreKitError.unknown")
        #expect(params["original_download_ts"] == nil)

        let fresh = Fixture()
        await fresh.engine.bootstrap(appVersion: "1.2.0")
        await fresh.engine.resolveInstall(originalDownload: Date(timeIntervalSince1970: 1_700_000_000), status: "ok")
        #expect(await fresh.engine.queuedEvents[0].params["prior_usage"] == nil)
    }

    @Test func fallbackEnvironmentHoldsFlushUntilResolved() async throws {
        let f = Fixture(context: ["env": "production"])
        await f.engine.record("a.one")
        await f.engine.flush()
        #expect(await f.transport.bodies.isEmpty)                  // Environment unresolved: hold sending.

        await f.engine.resolveEnvironment("sandbox")
        await f.engine.flush()
        let body = try #require(await f.transport.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["context"] as? [String: String])?["env"] == "sandbox")

        // After relaunch AppTransaction fails: reuse the remembered environment and do not hold sending.
        let again = Fixture(clock: f.clock, suite: f.suite, dir: f.dir, context: ["env": "production"])
        await again.engine.resolveEnvironment(nil)
        await again.engine.record("a.two")
        await again.engine.flush()
        let last = try #require(await again.transport.bodies.last)
        let json2 = try #require(try JSONSerialization.jsonObject(with: last) as? [String: Any])
        #expect((json2["context"] as? [String: String])?["env"] == "sandbox")
    }

    @Test func xcodeEnvironmentIsNeverOverridden() async throws {
        let f = Fixture(context: ["env": "production"])
        await f.engine.resolveEnvironment("sandbox")
        let debug = Fixture(clock: f.clock, suite: f.suite, dir: f.dir, context: ["env": "xcode"])
        await debug.engine.record("a")
        await debug.engine.flush()                                 // xcode never holds sending.
        let body = try #require(await debug.transport.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["context"] as? [String: String])?["env"] == "xcode")
    }

    @Test func missingDownloadTimeIsBackfilledOnce() async {
        let f = Fixture()
        #expect(await f.engine.claimAcquisitionAttempt() == false) // app.installed not sent yet.
        await f.engine.bootstrap(appVersion: "1.2.1")
        await f.engine.resolveInstall(originalDownload: nil, status: "error: unknown")

        #expect(await f.engine.claimAcquisitionAttempt())
        #expect(await f.engine.claimAcquisitionAttempt() == false) // No duplicate while in flight.
        await f.engine.resolveAcquisition(originalDownload: nil, status: "error: unknown")

        // Retry after relaunch; backfill is sent exactly once on success.
        let again = Fixture(clock: f.clock, suite: f.suite, dir: f.dir)
        #expect(await again.engine.claimAcquisitionAttempt())
        await again.engine.resolveAcquisition(originalDownload: Date(timeIntervalSince1970: 1_700_000_000), status: "ok")
        #expect(await again.names() == ["app.installed", "app.acquired"])
        let params = await again.engine.queuedEvents[1].params
        #expect(params["original_download_ts"] == "1700000000000")
        #expect(params["at_status"] == "ok")
        #expect(await again.engine.claimAcquisitionAttempt() == false)
    }

    @Test func skippedOrResolvedInstallNeedsNoBackfill() async {
        let debug = Fixture()
        await debug.engine.bootstrap(appVersion: "1.0")
        await debug.engine.resolveInstall(originalDownload: nil, status: "skipped")
        #expect(await debug.engine.claimAcquisitionAttempt() == false)

        let ok = Fixture()
        await ok.engine.bootstrap(appVersion: "1.0")
        await ok.engine.resolveInstall(originalDownload: Date(timeIntervalSince1970: 1_700_000_000), status: "ok")
        #expect(await ok.engine.claimAcquisitionAttempt() == false)
    }

    @Test func sessionResumesWithinTimeoutAndSplitsAfter() async {
        let f = Fixture()
        #expect(await f.engine.didBecomeActive())
        f.clock.advance(60)
        await f.engine.didEnterBackground()
        f.clock.advance(120)                      // Back within 2 minutes: same session.
        #expect(await f.engine.didBecomeActive() == false)
        f.clock.advance(30)
        await f.engine.didEnterBackground()
        let firstID = await f.engine.session?.id
        f.clock.advance(600)                      // After 10 minutes: new session.
        #expect(await f.engine.didBecomeActive())

        let events = await f.engine.queuedEvents
        #expect(events.map(\.name) == ["session.started", "session.ended", "session.started"])
        #expect(events[1].params["duration_s"] == "90")
        #expect(events[1].session == firstID)
        #expect(events[2].session != firstID)
    }

    @Test func sessionEndedIsRecoveredAfterRelaunch() async {
        let f = Fixture()
        await f.engine.didBecomeActive()
        f.clock.advance(45)
        await f.engine.didEnterBackground()
        f.clock.advance(3600)
        // Simulate a relaunch after the process was killed.
        let relaunched = Fixture(clock: f.clock, suite: f.suite, dir: f.dir)
        await relaunched.engine.didBecomeActive()
        let events = await relaunched.engine.queuedEvents
        #expect(events.map(\.name) == ["session.started", "session.ended", "session.started"])
        #expect(events[1].params["duration_s"] == "45")
    }

    @Test func killedInForegroundStartsNewSessionOnRelaunch() async {
        let f = Fixture()
        await f.engine.didBecomeActive()
        f.clock.advance(20)
        await f.engine.record("entry.created")
        f.clock.advance(3600)                     // Process killed in the foreground, reopened an hour later.
        let relaunched = Fixture(clock: f.clock, suite: f.suite, dir: f.dir)
        #expect(await relaunched.engine.didBecomeActive())
        let events = await relaunched.engine.queuedEvents
        #expect(events.map(\.name) == ["session.started", "entry.created", "session.ended", "session.started"])
        #expect(events[2].params["duration_s"] == "20")
    }

    @Test func launchSourceAttachesToNewSession() async {
        let f = Fixture()
        var config = HiwiKInsightConfiguration(appKey: "test", endpoint: URL(string: "https://example.com")!)
        config.launchSourceWindow = 60
        let engine = Engine(config: config, storageDirectory: f.dir, defaultsSuiteName: f.suite,
                            transport: f.transport, context: [:], now: { [clock = f.clock] in clock.now })
        await engine.didBecomeActive()
        await engine.setLaunchSource("widget_today")
        await engine.emitPendingSessionStart()
        await engine.setLaunchSource("notification_reminder")   // Opened again from an external entry mid-session.
        let events = await engine.queuedEvents
        #expect(events.map(\.name) == ["session.started", "app.opened"])
        #expect(events[0].params["source"] == "widget_today")
        #expect(events[1].params["source"] == "notification_reminder")
    }

    @Test func flushHandlesAcceptRejectRetry() async throws {
        let f = Fixture()
        await f.engine.record("a.one")
        await f.transport.set([.retry])
        await f.engine.flush()
        #expect(await f.engine.queuedEvents.count == 1)          // 5xx: keep.
        await f.engine.flush()
        #expect(await f.transport.bodies.count == 1)              // No resend during backoff.
        f.clock.advance(31)
        await f.transport.set([.rejected(400)])
        await f.engine.flush()
        #expect(await f.engine.queuedEvents.isEmpty)             // 4xx: drop.

        await f.engine.record("a.two", ["k": "v"])
        await f.engine.flush()
        #expect(await f.engine.queuedEvents.isEmpty)
        let body = try #require(await f.transport.bodies.last)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["schema"] as? Int == 1)
        #expect(json["app"] as? String == "test")
        #expect(json["install_id"] as? String == f.engine.installID)
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(events.first?["name"] as? String == "a.two")
    }

    @Test func queuePersistsAndCaps() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let q = EventQueue(directory: dir, capacity: 3)
        for i in 0..<5 {
            q.append(QueuedEvent(id: "\(i)", name: "e", ts: Int64(i), session: nil, params: [:]))
        }
        #expect(q.events.map(\.id) == ["2", "3", "4"])
        q.remove(ids: ["3"])
        let reloaded = EventQueue(directory: dir, capacity: 3)
        #expect(reloaded.events.map(\.id) == ["2", "4"])
    }

    @Test func disablingClearsQueue() async {
        let f = Fixture()
        await f.engine.record("a")
        await f.engine.setEnabled(false)
        await f.engine.record("b")
        #expect(await f.engine.queuedEvents.isEmpty)
    }

    @Test func paramsAreSanitized() {
        var params: [String: String] = [:]
        for i in 0..<30 { params["k\(i)"] = String(repeating: "x", count: 300) }
        let out = Limits.sanitize(params)
        #expect(out.count == 20)
        #expect(out.values.allSatisfy { $0.count == 200 })
    }

    @Test func dailySnapshotOncePerDay() async {
        let f = Fixture()
        #expect(await f.engine.claimDailySnapshot())
        #expect(await f.engine.claimDailySnapshot() == false)
        f.clock.advance(86400)
        #expect(await f.engine.claimDailySnapshot())
    }
}
