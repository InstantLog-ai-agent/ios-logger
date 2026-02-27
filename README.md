# SensorCore iOS SDK

Swift Package for sending logs to your [SensorCore](https://github.com/udevwork/SensorCore) server. Zero external dependencies, Swift Concurrency, fire-and-forget API.

## Installation

**Swift Package Manager** — add to your `Package.swift`:

```swift
.package(url: "https://github.com/sensorcore/ios", from: "1.1.0")
```

Or in Xcode: **File → Add Package Dependencies…** → paste the repo URL.

## Quick Start

```swift
import SensorCoreiOS

// 1. Configure once at app launch (AppDelegate / @main struct)
SensorCore.configure(
    apiKey: "sc_your_api_key",
    host: URL(string: "https://logs.your-server.com")!
)

// 2a. Fire-and-forget — no await needed, never throws (most common)
SensorCore.log("App launched")
SensorCore.log("User signed up", level: .info, userId: "user-uuid-123")
SensorCore.log("Payment failed", level: .error, metadata: ["code": "card_declined", "amount": 99])

// 2b. Async/await — when you need delivery confirmation
do {
    try await SensorCore.logAsync("Critical error before crash", level: .error)
} catch {
    print("Log failed: \(error.localizedDescription)")
}
```

## Configuration Options

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `apiKey` | `String` | — | Your project API key |
| `host` | `URL` | — | Your SensorCore server URL |
| `defaultUserId` | `String?` | `nil` | Auto-attached user ID for every log |
| `enabled` | `Bool` | `true` | Set `false` to silence all logs (e.g. SwiftUI Previews) |
| `timeout` | `TimeInterval` | `10` | Network request timeout in seconds |
| `persistFailedLogs` | `Bool` | `true` | Save failed logs to disk for auto-retry |
| `maxPendingLogs` | `Int` | `500` | Max entries buffered on disk |
| `pendingLogMaxAge` | `TimeInterval` | `86400` | Drop buffered entries older than this (24h) |

### Full config example

```swift
SensorCore.configure(
    apiKey: "sc_abc123",
    host: URL(string: "https://logs.example.com")!,
    defaultUserId: Auth.currentUser?.id,   // attach user to every log
    enabled: !ProcessInfo.processInfo.environment.keys.contains("XCODE_RUNNING_FOR_PREVIEWS"),
    timeout: 15,
    persistFailedLogs: true,               // save failed logs to disk (default)
    maxPendingLogs: 500,                   // max buffered entries on disk
    pendingLogMaxAge: 86400                // drop entries older than 24h
)
```

## Log Levels

| Level | Use case |
|-------|----------|
| `.info` | General events (default) |
| `.warning` | Recoverable issues |
| `.error` | Failures — triggers error indicator in dashboard |
| `.messages` | User-facing messages / chat events |

## Metadata

Pass a `[String: Any]` dictionary. Supported value types: `String`, `Int`, `Double`, `Float`, `Bool`.
Unsupported types (arrays, nested objects) are silently dropped.

```swift
SensorCore.log("Purchase completed", metadata: [
    "product_id": "sku-42",
    "price": 9.99,
    "is_trial": false,
    "attempt": 1
])
```

## Error Handling

When using `logAsync`, you can catch typed `SensorCoreError` cases:

```swift
do {
    try await SensorCore.logAsync("Event", level: .info)
} catch let error as SensorCoreError {
    switch error {
    case .notConfigured:            // forgot to call configure()
    case .networkError(let e):      // no internet / timeout
    case .serverError(let code):    // server returned 4xx / 5xx
    case .encodingFailed(let e):    // metadata serialisation failed
    case .rateLimited:              // server returned 429 — logging is now suspended
    }
}
```

### Rate Limiting

If the server returns **HTTP 429**, the SDK permanently suspends all logging for the current app session (circuit-breaker pattern). No further network requests are made until the app is relaunched. This prevents a log loop from hammering the server.

## Offline Buffering

When a log fails to send (e.g. no internet in a tunnel), the SDK automatically:

1. **Saves** the entry to disk (`Library/Caches/SensorCore/pending.jsonl`)
2. **Monitors** connectivity via `NWPathMonitor`
3. **Retries** all pending entries when the network returns
4. **Flushes** entries from previous app sessions on next launch

Each entry keeps its **original timestamp** from when `log()` was called, so analytics order is preserved even if delivery is delayed by minutes or hours.

**Safeguards:**

- Max **500 entries** on disk (~500 KB) — oldest dropped when full
- Max **3 retry attempts** per entry — then permanently dropped
- **24-hour TTL** — stale entries are pruned automatically
- **No permissions required** — uses the app's private sandbox
- Configurable via `persistFailedLogs`, `maxPendingLogs`, `pendingLogMaxAge`
- Set `persistFailedLogs: false` to disable entirely

## Remote Config

Fetch feature flags and configuration values from your SensorCore server at runtime — no app release needed. An AI agent (via MCP) or the dashboard can update flags and the app picks them up immediately.

```swift
// Call at startup or on app foreground
let config = await SensorCore.remoteConfig()

// Typed accessors — always nil-safe, never crash
if config.bool(for: "show_new_onboarding") == true {
    showNewOnboarding()
}
let timeout = config.double(for: "api_timeout_seconds") ?? 30.0
let variant = config.string(for: "paywall_variant") ?? "control"
let retries = config.int(for: "max_retries") ?? 3
```

`remoteConfig()` **never throws and never crashes** — if the server is unreachable or returns an error, it returns an empty config.

| Accessor | Returns | Notes |
|---|---|---|
| `bool(for:)` | `Bool?` | `nil` if absent or wrong type |
| `string(for:)` | `String?` | `nil` if absent or wrong type |
| `double(for:)` | `Double?` | Also promotes `Int` values |
| `int(for:)` | `Int?` | Only exact integers |
| `config["key"]` | `Any?` | Raw subscript |
| `config.raw` | `[String: Any]` | Full decoded dictionary |

Always provide a default value (`?? yourDefault`) — the server may return nothing on first cold start.

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.5+
- Xcode 13+
