# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/).

## 0.4.0

- `trackScreen` records `screen.left` when the app enters the background and `screen.viewed` again
  when it becomes active, so dwell time no longer includes time spent in the background.
- Added `screenTrackingActive(_:)` for containers that stay mounted while hidden (tabs switched by
  opacity). Screens inside an inactive container record `screen.left`, and `screen.viewed` again
  when it becomes active.
- `HiwiKInsightKitVersion.current` now reports the package version (it still said 0.2.0 in 0.3.0).
- No wire-protocol changes.

## 0.3.0

- Added `beginPurchase(product:context:appAccountToken:)` for apps that already pass their own fixed
  `appAccountToken` (for example an account ID) to StoreKit. It records the same `purchase.started`
  event with that token (lowercase) and returns it unchanged. Attributing repeated tokens needs
  HiwiKInsight server v1.1.1 or later; older servers attribute every purchase of the token to its first attempt.
- No other wire-protocol changes; `PROTOCOL.md` now states that a `token` may repeat.

## 0.2.0

Open-source release.

- Renamed the package, product, module and target from `HiwikInsightKit` to `HiwiKInsightKit`.
- Renamed public symbols: `HiwikInsight` -> `HiwiKInsight`,
  `HiwikInsightConfiguration` -> `HiwiKInsightConfiguration`.
- English source comments and documentation (`README.md`, `PROTOCOL.md`), plus a Chinese README.
- Added `LICENSE` (MIT), `CONTRIBUTING.md` and `AGENTS.md`.
- No wire-protocol changes: schema 1, `POST /v1/events`, same JSON fields, headers and compression.
- Persisted storage is unchanged for backward compatibility: UserDefaults keys keep the
  `hiwik_insight.` prefix and the queue stays in `Application Support/HiwikInsight/<appKey>/`, so
  existing installs keep their install id, session state and unsent events after upgrading.

### Migrating from 0.1.x

Update the package URL / name, then replace `import HiwikInsightKit` with `import HiwiKInsightKit`,
`HiwikInsight.` with `HiwiKInsight.` and `HiwikInsightConfiguration` with `HiwiKInsightConfiguration`.

## History (pre-open-source)

### 0.1.3

- Remember the environment from the last successful `AppTransaction` and reuse it when it cannot be
  obtained. A Release build that has never obtained one holds sending until it resolves, so
  TestFlight builds do not fall back to `production`.
- If `app.installed` lacked the original download date, retry `AppTransaction` on each new session
  and send a one-time `app.acquired` event once it succeeds.

### 0.1.2

- `app.installed` now reports the `AppTransaction` outcome as `at_status`
  (`ok` / `unverified` / `skipped` / `timeout` / `error: ...`).
- Retry a failed `AppTransaction` once after 2 seconds.
- Added `hasPriorUsage` configuration, reported as `prior_usage=1`, so the server does not count
  users who had the app before the SDK was integrated as new users.

### 0.1.1

- No longer rely on the presence of a receipt file to decide whether to fetch `AppTransaction`
  (newer OS versions may not have one for App Store / TestFlight installs). Only simulator and
  Debug builds skip it.

### 0.1.0

- Initial version: anonymous install id, automatic install / update / session events and device
  context, disk-backed batched upload with DEFLATE compression and backoff, `trackScreen`,
  `setLaunchSource`, and purchase attribution via `beginPurchase` (`appAccountToken`).
