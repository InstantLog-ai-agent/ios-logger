import Foundation

/// Main entry point for the SensorCore SDK.
///
/// ## Setup
/// Call `configure` once at app launch, e.g. in `AppDelegate` or the `@main` struct:
/// ```swift
/// SensorCore.configure(
///     apiKey: "il_your_api_key",
///     host: URL(string: "https://logs.example.com")!
/// )
/// ```
///
/// ## Logging
/// ```swift
/// // Fire-and-forget (most common)
/// SensorCore.log("User signed up")
/// SensorCore.log("Payment failed", level: .error, metadata: ["code": "card_declined"])
///
/// // Async — when you need to know the result
/// try await SensorCore.logAsync("Critical event", level: .error)
/// ```
///
/// ## Remote Config
/// ```swift
/// let config = await SensorCore.remoteConfig()
/// if config.bool(for: "show_new_feature") == true {
///     // feature enabled via SensorCore dashboard or AI agent
/// }
/// ```
public final class SensorCore: @unchecked Sendable {

    // MARK: - Singleton

    /// The shared SDK instance.
    ///
    /// In most cases interact through the static API (`SensorCore.log(...)`, `SensorCore.configure(...)`).
    /// Direct access to `shared` is useful when you need the current config at runtime.
    public static let shared = SensorCore()
    private init() {}

    // MARK: - State

    /// The active networking actor. `nil` until ``configure(_:)`` is called,
    /// or when the SDK is explicitly disabled via ``SensorCoreConfig/enabled``.
    private var client: SensorCoreClient?

    /// The current configuration snapshot. Set atomically under `lock`.
    private var config: SensorCoreConfig?

    /// Protects concurrent writes to `client` and `config`.
    /// `NSLock` is sufficient because `configure()` is called rarely and is always synchronous.
    private let lock = NSLock()

    // MARK: - Configuration

    /// Configure the SDK. Must be called before any `log` calls.
    ///
    /// - Parameters:
    ///   - apiKey: Your project API key.
    ///   - host: Base URL of your SensorCore server.
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
        let cfg = SensorCoreConfig(
            apiKey: apiKey,
            host: host,
            defaultUserId: defaultUserId,
            enabled: enabled,
            timeout: timeout
        )
        shared.configure(cfg)
    }

    /// Configure the SDK with a pre-built ``SensorCoreConfig``.
    public static func configure(_ config: SensorCoreConfig) {
        shared.configure(config)
    }

    // MARK: - Public API

    /// Send a log entry. **Fire-and-forget** — returns immediately, never throws.
    ///
    /// - Parameters:
    ///   - content: Log message (max 5000 characters).
    ///   - level: Severity level (default `.info`).
    ///   - userId: Overrides the `defaultUserId` set in config.
    ///   - metadata: Arbitrary key-value pairs (`String`, `Int`, `Double`, `Float`, `Bool`).
    public static func log(
        _ content: String,
        level: SensorCoreLevel = .info,
        userId: String? = nil,
        metadata: [String: Any]? = nil
    ) {
        shared.fireAndForget(content, level: level, userId: userId, metadata: metadata)
    }

    /// Send a log entry and **await** the result. Throws ``SensorCoreError`` on failure.
    ///
    /// Use this when you need confirmation the log was delivered, e.g. before crashing.
    ///
    /// - Parameters:
    ///   - content: Log message (max 5000 characters).
    ///   - level: Severity level (default `.info`).
    ///   - userId: Overrides the `defaultUserId` set in config.
    ///   - metadata: Arbitrary key-value pairs (`String`, `Int`, `Double`, `Float`, `Bool`).
    /// - Throws: ``SensorCoreError``
    public static func logAsync(
        _ content: String,
        level: SensorCoreLevel = .info,
        userId: String? = nil,
        metadata: [String: Any]? = nil
    ) async throws {
        try await shared.sendAsync(content, level: level, userId: userId, metadata: metadata)
    }

    /// Fetch the current Remote Config flags from the SensorCore server.
    ///
    /// Always safe to call — returns an empty ``SensorCoreRemoteConfig`` if:
    /// - The SDK has not been configured yet
    /// - The server is unreachable
    /// - The server returns a non-2xx response
    /// - The response body is not valid JSON
    ///
    /// ```swift
    /// let config = await SensorCore.remoteConfig()
    ///
    /// if config.bool(for: "show_new_onboarding") == true {
    ///     showNewOnboarding()
    /// }
    /// let threshold = config.double(for: "warning_threshold") ?? 0.8
    /// ```
    ///
    /// - Returns: An ``SensorCoreRemoteConfig`` with all current flags, or an empty config on failure.
    public static func remoteConfig() async -> SensorCoreRemoteConfig {
        await shared.fetchConfig()
    }

    // MARK: - Private helpers

    /// Atomically replaces the active configuration and networking client.
    ///
    /// The lock guarantees that a concurrent `log()` on another thread always sees
    /// a consistent (`config`, `client`) pair — never one without the other.
    /// A startup banner is printed to the Xcode console in `DEBUG` builds.
    private func configure(_ cfg: SensorCoreConfig) {
        lock.withLock {
            self.config = cfg
            self.client = cfg.enabled ? SensorCoreClient(config: cfg) : nil
        }
        #if DEBUG
        if cfg.enabled {
            print("""
            [SensorCore] ✅ configured
              Host:    \(cfg.host.absoluteString)
              User:    \(cfg.defaultUserId ?? "(none)")
              Timeout: \(Int(cfg.timeout))s
            """)
        } else {
            print("[SensorCore] ⚠️  SDK is disabled (enabled: false). No logs will be sent.")
        }
        #endif
    }

    /// Fetches Remote Config via the actor. Returns empty config if not configured.
    private func fetchConfig() async -> SensorCoreRemoteConfig {
        let client = lock.withLock { self.client }
        guard let client else { return .empty }
        return await client.fetchRemoteConfig()
    }

    /// Validates state and builds a log entry ready for dispatch.
    ///
    /// Returns `nil` if the SDK is unconfigured or disabled so call sites can stay
    /// synchronous and non-throwing. Messages longer than 5000 chars are silently
    /// truncated to 4997 chars + `"..."` to satisfy the server character limit.
    ///
    /// - Returns: A `(entry, client)` tuple, or `nil` when logging should be skipped.
    private func prepareEntry(
        _ content: String,
        level: SensorCoreLevel,
        userId: String?,
        metadata: [String: Any]?
    ) -> (entry: SensorCoreEntry, client: SensorCoreClient)? {
        // Read client and config atomically. Without the lock, a concurrent configure()
        // call on another thread could leave us with a mismatched pair (old client, new config).
        let (client, config) = lock.withLock { (self.client, self.config) }
        guard let client, let config else { return nil }
        let resolvedUserId = userId ?? config.defaultUserId
        let truncated = content.count > 5000 ? String(content.prefix(4997)) + "..." : content
        let entry = SensorCoreEntry(content: truncated, level: level, userId: resolvedUserId, metadata: metadata)
        return (entry, client)
    }

    /// Enqueues a log entry via the internal AsyncStream queue. **Synchronous, never throws.**
    ///
    /// Calls ``SensorCoreClient/enqueue(_:)`` which is `nonisolated` — returns immediately
    /// without creating a `Task` or suspending the caller. Network I/O happens on
    /// the queue's single consumer Task.
    private func fireAndForget(
        _ content: String,
        level: SensorCoreLevel,
        userId: String?,
        metadata: [String: Any]?
    ) {
        guard let (entry, client) = prepareEntry(content, level: level, userId: userId, metadata: metadata) else {
            #if DEBUG
            debugPrint("[SensorCore] Not configured. Call SensorCore.configure(...) at app startup.")
            #endif
            return
        }
        // enqueue() is nonisolated and synchronous — no Task created per call.
        // The single consumer Task inside SensorCoreClient drains the queue in the background.
        client.enqueue(entry)
    }

    /// Sends a log entry directly (bypassing the queue) and awaits delivery.
    ///
    /// Wrapped in `Task.detached` to guarantee execution off `@MainActor`
    /// even when `logAsync()` is called from a SwiftUI view or another `@MainActor` context.
    ///
    /// - Throws: ``SensorCoreError`` on any failure.
    private func sendAsync(
        _ content: String,
        level: SensorCoreLevel,
        userId: String?,
        metadata: [String: Any]?
    ) async throws {
        guard let (entry, client) = prepareEntry(content, level: level, userId: userId, metadata: metadata) else {
            throw SensorCoreError.notConfigured
        }
        // Detach from the caller's actor context so the network work never runs on @MainActor,
        // even if logAsync() is called from a SwiftUI view or other @MainActor context.
        try await Task.detached(priority: .utility) {
            try await client.sendThrowing(entry: entry)
        }.value
    }
}
