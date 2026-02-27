import Foundation

/// Configuration bag passed to ``SensorCore/configure(_:)`` at app startup.
///
/// All properties except `apiKey` and `host` have sensible defaults,
/// so the minimal setup is just two lines:
/// ```swift
/// let config = SensorCoreConfig(
///     apiKey: "il_your_key",
///     host:   URL(string: "https://logs.example.com")!
/// )
/// SensorCore.configure(config)
/// ```
public struct SensorCoreConfig: Sendable {

    // MARK: - Required

    /// Your project's API key.
    ///
    /// Found in the SensorCore dashboard under **Project → Settings → API Key**.
    /// Kept in memory only; never written to disk by the SDK.
    public var apiKey: String

    /// Base URL of the SensorCore server that will receive the logs.
    ///
    /// Must include the scheme, e.g. `https://logs.example.com`.
    /// Do **not** include a trailing slash or path — the SDK appends `/api/logs` automatically.
    public var host: URL

    // MARK: - Optional

    /// A stable identifier for the currently signed-in user (e.g. a UUID string).
    ///
    /// When set, this value is attached to every log entry automatically.
    /// You can still pass a different `userId` per-call to ``SensorCore/log(_:level:userId:metadata:)``
    /// which will override this default for that single call.
    ///
    /// Tip: update this whenever the user signs in or out:
    /// ```swift
    /// SensorCore.shared.config?.defaultUserId = Auth.currentUser?.id
    /// ```
    public var defaultUserId: String?

    /// When `false`, every ``SensorCore/log(_:level:userId:metadata:)`` call is a silent no-op.
    ///
    /// Useful patterns:
    /// ```swift
    /// // Disable in SwiftUI Previews
    /// enabled: !ProcessInfo.processInfo.environment.keys.contains("XCODE_RUNNING_FOR_PREVIEWS")
    ///
    /// // Disable in unit tests
    /// enabled: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    /// ```
    public var enabled: Bool

    /// Maximum time (in seconds) to wait for the server to respond before the request is cancelled.
    ///
    /// Default is `10` seconds. Raise this value on unreliable networks;
    /// lower it if you want faster failure detection.
    public var timeout: TimeInterval

    // MARK: - Offline Buffering

    /// When `true` (the default), log entries that fail to send due to network errors
    /// are saved to disk and automatically retried when connectivity returns.
    ///
    /// Set to `false` to disable offline buffering entirely — failed logs will be
    /// silently dropped, matching the SDK's original behavior.
    ///
    /// ```swift
    /// // Disable offline buffering (not recommended)
    /// SensorCore.configure(
    ///     apiKey: "key",
    ///     host: url,
    ///     persistFailedLogs: false
    /// )
    /// ```
    public var persistFailedLogs: Bool

    /// Maximum number of log entries that can be stored on disk awaiting retry.
    ///
    /// When this limit is reached, the **oldest** pending entries are discarded
    /// to make room for newer ones. The default of `500` keeps disk usage under ~500 KB.
    public var maxPendingLogs: Int

    /// Maximum age (in seconds) for a pending log entry before it is discarded.
    ///
    /// Entries older than this are pruned during retry to avoid sending stale data
    /// that may confuse time-sensitive analytics. Default is `86400` (24 hours).
    public var pendingLogMaxAge: TimeInterval

    // MARK: - Init

    /// Creates a new SDK configuration.
    ///
    /// - Parameters:
    ///   - apiKey: Your project API key from the SensorCore dashboard.
    ///   - host: Base URL of your SensorCore server (no trailing slash).
    ///   - defaultUserId: Optional user identifier attached to every log. Default: `nil`.
    ///   - enabled: Set to `false` to disable all logging. Default: `true`.
    ///   - timeout: Network request timeout in seconds. Default: `10`.
    ///   - persistFailedLogs: Save failed logs to disk for retry. Default: `true`.
    ///   - maxPendingLogs: Max entries stored on disk. Default: `500`.
    ///   - pendingLogMaxAge: Max age in seconds before stale entries are dropped. Default: `86400` (24h).
    public init(
        apiKey: String,
        host: URL,
        defaultUserId: String? = nil,
        enabled: Bool = true,
        timeout: TimeInterval = 10,
        persistFailedLogs: Bool = true,
        maxPendingLogs: Int = 500,
        pendingLogMaxAge: TimeInterval = 86400
    ) {
        self.apiKey = apiKey
        self.host = host
        self.defaultUserId = defaultUserId
        self.enabled = enabled
        self.timeout = timeout
        self.persistFailedLogs = persistFailedLogs
        self.maxPendingLogs = maxPendingLogs
        self.pendingLogMaxAge = pendingLogMaxAge
    }
}
