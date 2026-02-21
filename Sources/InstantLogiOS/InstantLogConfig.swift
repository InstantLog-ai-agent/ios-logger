import Foundation

/// Configuration bag passed to ``InstantLog/configure(_:)`` at app startup.
///
/// All properties except `apiKey` and `host` have sensible defaults,
/// so the minimal setup is just two lines:
/// ```swift
/// let config = InstantLogConfig(
///     apiKey: "il_your_key",
///     host:   URL(string: "https://logs.example.com")!
/// )
/// InstantLog.configure(config)
/// ```
public struct InstantLogConfig: Sendable {

    // MARK: - Required

    /// Your project's API key.
    ///
    /// Found in the InstantLog dashboard under **Project → Settings → API Key**.
    /// Kept in memory only; never written to disk by the SDK.
    public var apiKey: String

    /// Base URL of the InstantLog server that will receive the logs.
    ///
    /// Must include the scheme, e.g. `https://logs.example.com`.
    /// Do **not** include a trailing slash or path — the SDK appends `/api/logs` automatically.
    public var host: URL

    // MARK: - Optional

    /// A stable identifier for the currently signed-in user (e.g. a UUID string).
    ///
    /// When set, this value is attached to every log entry automatically.
    /// You can still pass a different `userId` per-call to ``InstantLog/log(_:level:userId:metadata:)``
    /// which will override this default for that single call.
    ///
    /// Tip: update this whenever the user signs in or out:
    /// ```swift
    /// InstantLog.shared.config?.defaultUserId = Auth.currentUser?.id
    /// ```
    public var defaultUserId: String?

    /// When `false`, every ``InstantLog/log(_:level:userId:metadata:)`` call is a silent no-op.
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

    // MARK: - Init

    /// Creates a new SDK configuration.
    ///
    /// - Parameters:
    ///   - apiKey: Your project API key from the InstantLog dashboard.
    ///   - host: Base URL of your InstantLog server (no trailing slash).
    ///   - defaultUserId: Optional user identifier attached to every log. Default: `nil`.
    ///   - enabled: Set to `false` to disable all logging. Default: `true`.
    ///   - timeout: Network request timeout in seconds. Default: `10`.
    public init(
        apiKey: String,
        host: URL,
        defaultUserId: String? = nil,
        enabled: Bool = true,
        timeout: TimeInterval = 10
    ) {
        self.apiKey = apiKey
        self.host = host
        self.defaultUserId = defaultUserId
        self.enabled = enabled
        self.timeout = timeout
    }
}
