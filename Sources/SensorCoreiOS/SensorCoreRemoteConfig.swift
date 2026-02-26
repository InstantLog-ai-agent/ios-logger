import Foundation

// MARK: - SensorCoreRemoteConfig

/// A snapshot of Remote Config flags fetched from the SensorCore server.
///
/// Always safe to use — if the server is unreachable, returns no flags.
/// Access values with typed helpers or the generic subscript:
///
/// ```swift
/// let config = await SensorCore.remoteConfig()
///
/// // Typed helpers
/// if config.bool(for: "show_new_onboarding") == true {
///     showNewOnboarding()
/// }
/// let timeout = config.double(for: "api_timeout_seconds") ?? 30.0
///
/// // Generic subscript (returns Any?)
/// let raw = config["experiment_variant"]
/// ```
///
/// All typed accessors return `nil` when the key is absent or has a different type —
/// they never crash and never throw.
public struct SensorCoreRemoteConfig: @unchecked Sendable {

    // MARK: - Public state

    /// The raw decoded JSON dictionary. All values are one of:
    /// `String`, `Bool`, `Double`, `Int`, or `NSNull`.
    public let raw: [String: Any]

    // MARK: - Subscript

    /// Returns the raw value for `key`, or `nil` if absent.
    public subscript(key: String) -> Any? {
        raw[key]
    }

    // MARK: - Typed accessors

    /// Returns the value for `key` as `String`, or `nil` if absent or not a `String`.
    public func string(for key: String) -> String? {
        raw[key] as? String
    }

    /// Returns the value for `key` as `Bool`, or `nil` if absent or not a `Bool`.
    ///
    /// > Note: JSON booleans are decoded as `Bool` by `JSONSerialization`.
    /// > A string `"true"` would not match — use `string(for:)` in that case.
    public func bool(for key: String) -> Bool? {
        raw[key] as? Bool
    }

    /// Returns the value for `key` as `Double`, or `nil` if absent or not numeric.
    ///
    /// This also accepts integer values from the server (e.g. `42` → `42.0`).
    public func double(for key: String) -> Double? {
        if let d = raw[key] as? Double { return d }
        if let i = raw[key] as? Int    { return Double(i) }
        return nil
    }

    /// Returns the value for `key` as `Int`, or `nil` if absent or not an integer.
    public func int(for key: String) -> Int? {
        if let i = raw[key] as? Int    { return i }
        if let d = raw[key] as? Double { return Int(exactly: d) }
        return nil
    }

    // MARK: - Internal init

    /// Creates a config from a raw decoded JSON dictionary.
    /// Pass `[:]` for the empty / error case.
    init(raw: [String: Any]) {
        self.raw = raw
    }

    /// Convenience empty config (server unreachable, not configured, etc.)
    static let empty = SensorCoreRemoteConfig(raw: [:])
}
