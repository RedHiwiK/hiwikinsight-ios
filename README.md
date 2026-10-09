<p align="center">
  <img src=".github/logo.svg" width="128" height="128" alt="HiwiKInsightKit logo">
</p>

<h1 align="center">HiwiKInsightKit</h1>

<p align="center"><strong>Privacy-first iOS analytics SDK for your self-hosted HiwiKInsight server.</strong></p>

<p align="center">
  <a href="https://github.com/RedHiwiK/hiwikinsight-ios/actions/workflows/ci.yml"><img src="https://github.com/RedHiwiK/hiwikinsight-ios/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple&logoColor=white" alt="iOS 17+">
  <img src="https://img.shields.io/badge/SwiftPM-compatible-F05138" alt="SwiftPM compatible">
  <img src="https://img.shields.io/badge/dependencies-none-0FB5AE" alt="dependencies: none">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2EA44F" alt="License MIT"></a>
</p>

<p align="center">
  <a href="#installation">Installation</a> · <a href="#quick-start">Quick start</a> · <a href="https://github.com/RedHiwiK/HiwiKInsight">Server</a> · <a href="README.zh-CN.md">简体中文</a>
</p>

A small, dependency-free, privacy-first analytics SDK for iOS apps. It records anonymous usage
events and sends them in compressed batches to your own self-hosted
[HiwiKInsight](https://github.com/RedHiwiK/HiwiKInsight) server.

- Zero third-party dependencies, Swift 6, iOS 17+
- Automatic install / update / session / screen tracking
- Launch-source and in-app-purchase attribution
- Disk-backed queue: events survive crashes and offline periods

The wire protocol is documented in [PROTOCOL.md](PROTOCOL.md); it is the only contract between
the SDK and the server.

## Privacy

- **Anonymous install id.** Each install gets a random UUID stored in `UserDefaults`. It is not
  derived from any device identifier, is neither the IDFA nor the IDFV, and changes when the app
  is reinstalled.
- **No PII.** The SDK collects no names, emails, phone numbers, contacts, location or advertising
  identifiers. Only send bucketed, non-identifying values in your own params
  (e.g. `"entry_count": "10-50"` rather than exact values or free text).
- **No IP addresses.** The SDK does not collect IP addresses, and the HiwiKInsight ingest endpoint
  does not store them with events.
- **No cross-app tracking.** Data goes only to the server you configure.
- `HiwiKInsight.setEnabled(false)` stops collection and deletes all unsent events, e.g. to honor
  an in-app opt-out.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/RedHiwiK/hiwikinsight-ios", from: "0.2.0"),
]
```

Or in Xcode: **File > Add Package Dependencies...** and enter
`https://github.com/RedHiwiK/hiwikinsight-ios`.

## Quick start

```swift
import HiwiKInsightKit

// 1. Start once at launch (e.g. in your App's init).
HiwiKInsight.start(.init(appKey: "pawprint", endpoint: URL(string: "https://insight.example.com")!)) {
    // Optional user snapshot, sent once per day on the first session. Use bucketed values.
    ["entry_count": "10-50", "is_pro": "true"]
}

// 2. Custom events.
HiwiKInsight.signal("entry.created", ["entry_type": "note"])

// 3. Errors.
HiwiKInsight.error(id: "sync.failed", category: "thrown-exception", message: "timeout")

// 4. Screens (SwiftUI): screen.viewed on appear, screen.left with dwell time on disappear.
SettingsView().trackScreen("settings", module: "settings")

// 5. Launch source: call when opened from a widget, notification, shortcut, etc.
HiwiKInsight.setLaunchSource("widget_today")

// 6. Purchase attribution: the returned UUID links the purchase to this entry point
//    via StoreKit's appAccountToken and App Store Server Notifications.
let token = HiwiKInsight.beginPurchase(product: product.id, context: "paywall_onboarding")
let result = try await product.purchase(options: [.appAccountToken(token)])
```

`trackScreen` belongs on standalone screens (the root of a push / fullScreenCover / sheet). For
tab roots that stay mounted, call `HiwiKInsight.screenViewed(_:module:)` where the tab changes.

### Collected automatically

- `app.installed`, `app.acquired`, `app.updated`
- `session.started` / `session.ended` (a new session starts after more than 5 minutes in the background)
- Batch context: app version and build, OS and version, device model, locale, language, region,
  App Store storefront, environment (`production` / `sandbox` / `xcode`), appearance, Dynamic Type size

See [PROTOCOL.md](PROTOCOL.md#built-in-sdk-events) for every built-in event and its params.

## Configuration

`HiwiKInsightConfiguration` properties (everything except `appKey` and `endpoint` has a default):

| Property | Default | Description |
|---|---|---|
| `appKey` | (required) | App identifier; must be on the server's allow-list |
| `endpoint` | (required) | Base URL of your server; events go to `<endpoint>/v1/events` |
| `defaultsSuiteName` | `nil` | UserDefaults suite for install id and session state (`nil` = `.standard`) |
| `sessionTimeout` | `300` s | Background time after which a new session starts |
| `flushInterval` | `30` s | Periodic flush interval |
| `flushThreshold` | `50` | Flush immediately when this many events are queued |
| `maxQueuedEvents` | `2000` | Queue cap; oldest events are dropped beyond it |
| `launchSourceWindow` | `1.5` s | How long `session.started` waits for `setLaunchSource` |
| `hasPriorUsage` | `false` | Set to `true` if your app knows this device used it before the SDK was integrated; sent as `prior_usage=1` with `app.installed` |
| `debugLogging` | `false` | Log every event via `os.Logger` |

```swift
var config = HiwiKInsightConfiguration(appKey: "pawprint", endpoint: URL(string: "https://insight.example.com")!)
config.hasPriorUsage = LocalStore.hasExistingData
config.debugLogging = true
HiwiKInsight.start(config)
```

## Batching and offline behavior

- Events are first appended to `Application Support/HiwikInsight/<appKey>/queue.jsonl`, so they
  survive crashes and app kills. The queue holds up to 2000 events (oldest dropped first).
- Batches (up to 200 events) are sent when 50 events are queued, every 30 seconds, and when the
  app enters the background. Bodies are compressed with raw DEFLATE.
- `5xx`, `408`, `429` and network errors keep the batch and retry with backoff
  (30 s, 2 min, 10 min, 1 h). Other `4xx` responses drop the batch so bad data cannot block the queue.
- A Release build that has never obtained an `AppTransaction` holds sending until the environment
  is known, so TestFlight data does not leak into production.
- `await HiwiKInsight.flush()` sends the queue immediately.

## Requirements

- iOS 17+ (the package also builds on macOS 14+ so tests can run on a Mac)
- Swift 6 toolchain (Xcode 16+)

## Server

HiwiKInsightKit talks to [HiwiKInsight](https://github.com/RedHiwiK/HiwiKInsight), a self-hosted
ingest and dashboard server. See its
[SDK integration guide](https://github.com/RedHiwiK/HiwiKInsight/blob/main/docs/sdk-integration.md)
for registering an `appKey` and deploying the server.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Release notes are in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
