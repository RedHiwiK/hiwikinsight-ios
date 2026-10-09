import Foundation

/// SDK configuration. `appKey` must match an app identifier allowed by the server.
public struct HiwiKInsightConfiguration: Sendable {
    public var appKey: String
    /// Base URL of your server; events are posted to `<endpoint>/v1/events`.
    public var endpoint: URL
    /// UserDefaults suite that stores the install id and session state; `nil` uses `.standard`.
    public var defaultsSuiteName: String?
    /// Returning from the background after longer than this starts a new session.
    public var sessionTimeout: TimeInterval = 300
    /// Periodic flush interval.
    public var flushInterval: TimeInterval = 30
    /// Flush immediately once this many events are queued.
    public var flushThreshold = 50
    /// Queue capacity; the oldest events are dropped beyond it.
    public var maxQueuedEvents = 2000
    /// How long to hold `session.started` after a new session begins, giving the app time
    /// to report a widget / notification launch source.
    public var launchSourceWindow: TimeInterval = 1.5
    /// Whether this device has used the app before (decided by the app: existing local data,
    /// markers left by an older version, etc.). Sent as `prior_usage=1` with `app.installed`
    /// when the install id is first generated, so the server does not count users who had the
    /// app before the SDK was integrated as new users, even if AppTransaction cannot provide
    /// the original download date.
    public var hasPriorUsage = false
    public var debugLogging = false

    public init(appKey: String, endpoint: URL, defaultsSuiteName: String? = nil) {
        self.appKey = appKey
        self.endpoint = endpoint
        self.defaultsSuiteName = defaultsSuiteName
    }
}

struct QueuedEvent: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var ts: Int64
    var session: String?
    var params: [String: String]
}

struct Batch: Encodable {
    var schema = 1
    var sdk = HiwiKInsightKitVersion.current
    var app: String
    var installID: String
    var sentAt: Int64
    var context: [String: String]
    var events: [QueuedEvent]

    enum CodingKeys: String, CodingKey {
        case schema, sdk, app, context, events
        case installID = "install_id"
        case sentAt = "sent_at"
    }
}

enum HiwiKInsightKitVersion {
    static let current = "0.2.0"
}

extension Date {
    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}

enum Limits {
    static let batchSize = 200
    static let maxParams = 20
    static let maxKeyLength = 40
    static let maxValueLength = 200

    /// Same limits as the server. Anything beyond them is trimmed on the client first,
    /// so a whole batch is not rejected with a 4xx.
    static func sanitize(_ params: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in params.keys.sorted().prefix(maxParams) {
            out[String(key.prefix(maxKeyLength))] = String(params[key]!.prefix(maxValueLength))
        }
        return out
    }
}
