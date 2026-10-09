# HiwiKInsight Wire Protocol (schema 1)

This document is the single contract between the SDK (this repository) and the server
([RedHiwiK/HiwiKInsight](https://github.com/RedHiwiK/HiwiKInsight)). Any change to a field on
either side must be made here first.

## Request

```
POST <your-server>/v1/events
Content-Type: application/json
Content-Encoding: deflate        // optional; raw DEFLATE (RFC 1951, i.e. the output of Apple's NSData `.zlib`, no zlib header)
```

```json
{
  "schema": 1,
  "sdk": "0.2.0",
  "app": "pawprint",
  "install_id": "5b0c2f4e-…",
  "sent_at": 1790000000000,
  "context": {
    "app_version": "1.2.0",
    "build": "1",
    "os": "iOS",
    "os_version": "26.1",
    "device": "iPhone17,1",
    "locale": "en_US",
    "language": "en-US",
    "region": "US",
    "storefront": "USA",
    "env": "production",
    "appearance": "light",
    "text_size": "L"
  },
  "events": [
    {"id": "e1…", "name": "session.started", "ts": 1790000000000, "session": "s1…", "params": {"source": "icon"}}
  ]
}
```

| Field | Description |
|---|---|
| `schema` | Protocol version, currently `1`. Bumped only for breaking changes; the server must keep accepting older values. |
| `sdk` | SDK version string. |
| `app` | App identifier. The server only accepts identifiers on its allow-list (e.g. `pawprint`). |
| `install_id` | Anonymous install id, lowercase UUID. Changes when the app is deleted and reinstalled. |
| `sent_at` | Send time (client clock, milliseconds). The server computes clock skew as `received_at - sent_at` and corrects every event `ts`; if the skew exceeds 7 days it uses the receive time instead. |
| `context` | Attributes shared by the batch, taken at send time. Every field is optional. |
| `context.env` | `production` / `sandbox` (TestFlight) / `xcode` (debug). Taken from `AppTransaction.environment`; the device remembers the last result and reuses it when AppTransaction is unavailable. A Release build that has never obtained an AppTransaction on this device holds sending until AppTransaction resolves (success or give-up), so TestFlight builds do not fall back to `production`. |
| `context.storefront` | App Store country (ISO 3166-1 alpha-3); omitted when unavailable. |
| `context.appearance` | `light` / `dark` |
| `context.text_size` | Dynamic Type size bucket: `XS` `S` `M` `L` (default) `XL` `XXL` `XXXL` `A11Y` |
| `events[].id` | Client-generated lowercase UUID; the server deduplicates on it. |
| `events[].ts` | Event time (client clock, milliseconds). |
| `events[].session` | Session id; optional. |
| `events[].params` | String-to-string map. |

Limits (the server truncates or rejects anything beyond them): at most 200 events per batch;
request body at most 256 KB (at most 2 MB after decompression); event names match
`^[a-z0-9_.]{1,64}$`; at most 20 params per event, keys at most 40 characters, values at most
200 characters.

## Response

| Status | Meaning | SDK behavior |
|---|---|---|
| `202` `{"accepted": n}` | Accepted (including events ignored as duplicate ids) | Remove the batch from the queue |
| `4xx` (except 408 / 429) | The request itself is invalid (malformed, unknown app, over limits) | Drop the batch so poisoned data cannot block the queue |
| `5xx` / 408 / 429 / network error | Server temporarily unavailable | Keep the batch and retry with backoff (30 s → 2 min → 10 min → 1 h) |

## Built-in SDK events

| Event | Params | Description |
|---|---|---|
| `app.installed` | `original_download_ts`, `at_status`, `prior_usage` (all optional) | Sent when the install id is first generated. `original_download_ts` comes from `AppTransaction.originalPurchaseDate` (ms); `at_status` is the outcome of fetching AppTransaction (`ok` / `unverified: …` / `skipped` / `timeout` / `error: …`; a failure is retried once after 2 s); `prior_usage=1` means the app determined this device had used it before (e.g. existing local data). The server uses either of the latter to tell genuinely new users from users who installed the app before the SDK was integrated. |
| `app.acquired` | `original_download_ts`, `at_status` | If `app.installed` did not carry the original download date (and was not `skipped`), the SDK retries AppTransaction on each new session and sends this once when it succeeds (SDK 0.1.3+). The server uses it to correct the acquisition date. |
| `app.updated` | `from`, `to` | App version changed. |
| `session.started` | `source` | A new session started. `source` is `icon` (default) or the value the app set via `setLaunchSource` (e.g. `widget_today`, `notification_reminder`). |
| `session.ended` | `duration_s` | Session ended. Emitted on the next launch after the app stayed in the background longer than the session timeout; `ts` is the time the app entered the background. `duration_s` is the accumulated foreground time in seconds. |
| `app.opened` | `source` | The app was opened again from an external entry point (widget, notification) during an ongoing session. |
| `screen.viewed` | `screen`, `module`, plus the screen's own params | A screen appeared. |
| `screen.left` | `screen`, `module`, `duration_s` | A screen disappeared; dwell time in seconds. |
| `purchase.started` | `product`, `context`, `token` | A purchase was initiated. `token` is also passed to StoreKit as `appAccountToken` (lowercase UUID), so the server can link App Store Server Notifications to it. |
| `user.snapshot` | App-defined (bucketed values) | Sent once on the first session of each local calendar day. |
| `error` | `id`, `category`, `message` | Error report. |

Reserved param names: `app`, `type`, `ts`, `session`, `install_id`. Do not use them for your own params.
