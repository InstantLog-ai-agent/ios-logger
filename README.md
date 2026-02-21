# InstantLog iOS SDK

Swift Package for sending logs to your [InstantLog](https://github.com/udevwork/instantlog) server. Zero external dependencies, Swift Concurrency, fire-and-forget API.

## Installation

**Swift Package Manager** — add to your `Package.swift`:

```swift
.package(url: "https://github.com/YOUR_ORG/InstantLogiOS", from: "1.0.0")
```

Or in Xcode: **File → Add Package Dependencies…** → paste the repo URL.

## Quick Start

```swift
import InstantLogiOS

// 1. Configure once at app launch (AppDelegate / @main struct)
InstantLog.configure(
    apiKey: "il_your_api_key",
    host: URL(string: "https://logs.your-server.com")!
)

// 2a. Fire-and-forget — no await needed, never throws (most common)
InstantLog.log("App launched")
InstantLog.log("User signed up", level: .info, userId: "user-uuid-123")
InstantLog.log("Payment failed", level: .error, metadata: ["code": "card_declined", "amount": 99])

// 2b. Async/await — when you need delivery confirmation
do {
    try await InstantLog.logAsync("Critical error before crash", level: .error)
} catch {
    print("Log failed: \(error.localizedDescription)")
}
```

## Configuration Options

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `apiKey` | `String` | — | Your project API key |
| `host` | `URL` | — | Your InstantLog server URL |
| `defaultUserId` | `String?` | `nil` | Auto-attached user ID for every log |
| `enabled` | `Bool` | `true` | Set `false` to silence all logs (e.g. SwiftUI Previews) |
| `timeout` | `TimeInterval` | `10` | Network request timeout in seconds |

### Full config example

```swift
InstantLog.configure(
    apiKey: "il_abc123",
    host: URL(string: "https://logs.example.com")!,
    defaultUserId: Auth.currentUser?.id,   // attach user to every log
    enabled: !ProcessInfo.processInfo.environment.keys.contains("XCODE_RUNNING_FOR_PREVIEWS"),
    timeout: 15
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
InstantLog.log("Purchase completed", metadata: [
    "product_id": "sku-42",
    "price": 9.99,
    "is_trial": false,
    "attempt": 1
])
```

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
