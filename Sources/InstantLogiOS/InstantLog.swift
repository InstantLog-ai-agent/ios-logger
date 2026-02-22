import Foundation

/// Main entry point for the InstantLog SDK.
///
/// ## Setup
/// Call `configure` once at app launch, e.g. in `AppDelegate` or the `@main` struct:
/// ```swift
/// InstantLog.configure(
///     apiKey: "il_your_api_key",
///     host: URL(string: "https://logs.example.com")!
/// )
/// ```
///
/// ## Logging
/// ```swift
/// // Fire-and-forget (most common)
/// InstantLog.log("User signed up")
/// InstantLog.log("Payment failed", level: .error, metadata: ["code": "card_declined"])
///
/// // Async — when you need to know the result
/// try await InstantLog.logAsync("Critical event", level: .error)
/// ```
public final class InstantLog: @unchecked Sendable {

    // MARK: - Singleton

    /// The shared SDK instance.
    ///
    /// In most cases interact through the static API (`InstantLog.log(...)`, `InstantLog.configure(...)`).
    /// Direct access to `shared` is useful when you need the current config at runtime.
    public static let shared = InstantLog()
    private init() {}

    // MARK: - State

    /// The active networking actor. `nil` until ``configure(_:)`` is called,
    /// or when the SDK is explicitly disabled via ``InstantLogConfig/enabled``.
    private var client: InstantLogClient?

    /// The current configuration snapshot. Set atomically under `lock`.
    private var config: InstantLogConfig?

    /// Protects concurrent writes to `client` and `config`.
    /// `NSLock` is sufficient because `configure()` is called rarely and is always synchronous.
    private let lock = NSLock()

    // MARK: - Configuration

    /// Configure the SDK. Must be called before any `log` calls.
    ///
    /// - Parameters:
    ///   - apiKey: Your project API key.
    ///   - host: Base URL of your InstantLog server.
    ///   - defaultUserId: Optional user ID attached to every log (can be overridden per call).
    ///   - enabled: Set to `false` to silently disable all logging (e.g. in Previews).
    ///   - timeout: Network request timeout (default 10 s).
    public static func configure(
        apiKey: String,
        host: URL,
        defaultUserId: String? = nil,
        enabled: Bool = true,
        timeout: TimeInterval = 10
    ) {
        let cfg = InstantLogConfig(
            apiKey: apiKey,
            host: host,
            defaultUserId: defaultUserId,
            enabled: enabled,
            timeout: timeout
        )
        shared.configure(cfg)
    }

    /// Configure the SDK with a pre-built ``InstantLogConfig``.
    public static func configure(_ config: InstantLogConfig) {
        shared.configure(config)
    }

    // MARK: - Public API

    /// Send a log entry. **Fire-and-forget** — returns immediately, never throws.
    ///
    /// - Parameters:
    ///   - content: Log message (max 200 characters).
    ///   - level: Severity level (default `.info`).
    ///   - userId: Overrides the `defaultUserId` set in config.
    ///   - metadata: Arbitrary key-value pairs (`String`, `Int`, `Double`, `Float`, `Bool`).
    public static func log(
        _ content: String,
        level: InstantLogLevel = .info,
        userId: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        shared.fireAndForget(content, level: level, userId: userId, metadata: metadata)
    }

    /// Send a log entry and **await** the result. Throws ``InstantLogError`` on failure.
    ///
    /// Use this when you need confirmation the log was delivered, e.g. before crashing.
    ///
    /// - Parameters:
    ///   - content: Log message (max 200 characters).
    ///   - level: Severity level (default `.info`).
    ///   - userId: Overrides the `defaultUserId` set in config.
    ///   - metadata: Arbitrary key-value pairs (`String`, `Int`, `Double`, `Float`, `Bool`).
    /// - Throws: ``InstantLogError``
    public static func logAsync(
        _ content: String,
        level: InstantLogLevel = .info,
        userId: String? = nil,
        metadata: [String: Any]? = nil
    ) async throws {
        try await shared.sendAsync(content, level: level, userId: userId, metadata: metadata)
    }

    // MARK: - Private helpers

    /// Atomically replaces the active configuration and networking client.
    ///
    /// The lock guarantees that a concurrent `log()` on another thread always sees
    /// a consistent (`config`, `client`) pair — never one without the other.
    /// A startup banner is printed to the Xcode console in `DEBUG` builds.
    private func configure(_ cfg: InstantLogConfig) {
        lock.withLock {
            self.config = cfg
            self.client = cfg.enabled ? InstantLogClient(config: cfg) : nil
        }
        #if DEBUG
        if cfg.enabled {
            print("""
            [InstantLog] ✅ configured
              Host:    \(cfg.host.absoluteString)
              User:    \(cfg.defaultUserId ?? "(none)")
              Timeout: \(Int(cfg.timeout))s
            """)
        } else {
            print("[InstantLog] ⚠️  SDK is disabled (enabled: false). No logs will be sent.")
        }
        #endif
    }

    /// Validates state and builds a log entry ready for dispatch.
    ///
    /// Returns `nil` if the SDK is unconfigured or disabled so call sites can stay
    /// synchronous and non-throwing. Messages longer than 200 chars are silently
    /// truncated to 197 chars + `"..."` to satisfy the server character limit.
    ///
    /// - Returns: A `(entry, client)` tuple, or `nil` when logging should be skipped.
    private func prepareEntry(
        _ content: String,
        level: InstantLogLevel,
        userId: String?,
        metadata: [String: Any]?
    ) -> (entry: InstantLogEntry, client: InstantLogClient)? {
        // Read client and config atomically. Without the lock, a concurrent configure()
        // call on another thread could leave us with a mismatched pair (old client, new config).
        let (client, config) = lock.withLock { (self.client, self.config) }
        guard let client, let config else { return nil }
        let resolvedUserId = userId ?? config.defaultUserId
        let truncated = content.count > 200 ? String(content.prefix(197)) + "..." : content
        let entry = InstantLogEntry(content: truncated, level: level, userId: resolvedUserId, metadata: metadata)
        return (entry, client)
    }

    /// Enqueues a log entry via the internal AsyncStream queue. **Synchronous, never throws.**
    ///
    /// Calls ``InstantLogClient/enqueue(_:)`` which is `nonisolated` — returns immediately
    /// without creating a `Task` or suspending the caller. Network I/O happens on
    /// the queue's single consumer Task.
    private func fireAndForget(
        _ content: String,
        level: InstantLogLevel,
        userId: String?,
        metadata: [String: Any]?
    ) {
        guard let (entry, client) = prepareEntry(content, level: level, userId: userId, metadata: metadata) else {
            #if DEBUG
            debugPrint("[InstantLog] Not configured. Call InstantLog.configure(...) at app startup.")
            #endif
            return
        }
        // enqueue() is nonisolated and synchronous — no Task created per call.
        // The single consumer Task inside InstantLogClient drains the queue in the background.
        client.enqueue(entry)
    }

    /// Sends a log entry directly (bypassing the queue) and awaits delivery.
    ///
    /// Wrapped in `Task.detached` to guarantee execution off `@MainActor`
    /// even when `logAsync()` is called from a SwiftUI view or another `@MainActor` context.
    ///
    /// - Throws: ``InstantLogError`` on any failure.
    private func sendAsync(
        _ content: String,
        level: InstantLogLevel,
        userId: String?,
        metadata: [String: Any]?
    ) async throws {
        guard let (entry, client) = prepareEntry(content, level: level, userId: userId, metadata: metadata) else {
            throw InstantLogError.notConfigured
        }
        // Detach from the caller's actor context so the network work never runs on @MainActor,
        // even if logAsync() is called from a SwiftUI view or other @MainActor context.
        try await Task.detached(priority: .utility) {
            try await client.sendThrowing(entry: entry)
        }.value
    }
}
