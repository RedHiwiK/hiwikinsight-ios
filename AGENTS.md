# AGENTS.md

Guide for AI coding agents working in this repository.

## Layout

- `Package.swift`: single library target `HiwiKInsightKit` (iOS 17+, macOS 14+ for tests), Swift 6.
- `Sources/HiwiKInsightKit/`
  - `HiwiKInsight.swift`: public static API (`start`, `signal`, `error`, `beginPurchase`, `setLaunchSource`, `screenViewed`, `setEnabled`, `flush`) and UIKit lifecycle hooks.
  - `Engine.swift`: actor holding all state (install id, sessions, environment, flushing/backoff). Testable via injected clock, transport, defaults suite and storage directory.
  - `EventQueue.swift`: JSON Lines disk queue.
  - `Transport.swift`: HTTP `POST <endpoint>/v1/events` with raw DEFLATE.
  - `Models.swift`: public configuration, wire models (`Batch`), SDK version, param limits.
  - `DeviceInfo.swift`: device context and StoreKit `AppTransaction` / storefront lookups.
  - `ScreenTracking.swift`: SwiftUI `trackScreen` modifier.
- `Tests/HiwiKInsightKitTests/`: Swift Testing suite for the engine and queue.
- `PROTOCOL.md`: the wire protocol, the contract with the server.

## Commands

```sh
swift build
swift test
xcodebuild build -scheme HiwiKInsightKit -destination 'generic/platform=iOS Simulator'
```

## Rules

- **Protocol compatibility:** do not change JSON field names, the `/v1/events` path, headers,
  compression, `schema` value or built-in event names/params without updating `PROTOCOL.md` and
  the server ([RedHiwiK/HiwiKInsight](https://github.com/RedHiwiK/HiwiKInsight)). Deployed servers
  must keep working with new SDK versions.
- **Persisted storage is frozen:** UserDefaults keys (`hiwik_insight.*`) and the queue directory
  (`Application Support/HiwikInsight/<appKey>/`) keep their pre-0.2.0 spelling on purpose. Never rename them.
- No third-party dependencies; no personal data, IP addresses or device identifiers.
- Bump `HiwiKInsightKitVersion.current` and `CHANGELOG.md` when releasing.
- English for code, comments and docs (`README.zh-CN.md` is the only Chinese file).
