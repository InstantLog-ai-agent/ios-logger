/// Severity level of a log entry sent to the InstantLog server.
///
/// Matches the server-side `level` field values exactly.
/// The level is used in the dashboard for filtering, colouring, and analytics.
///
/// ## Usage
/// ```swift
/// InstantLog.log("Device storage low", level: .warning)
/// InstantLog.log("Payment declined",   level: .error)
/// ```
public enum InstantLogLevel: String, Sendable {

    /// General informational event. Default level. Use for normal app milestones,
    /// e.g. "User signed up", "Screen appeared".
    case info

    /// Something unexpected that the app recovered from, e.g. a retried network call
    /// or a missing optional value that was safely handled.
    case warning

    /// A failure that affects the user, e.g. a failed payment or an unrecoverable crash.
    /// Sending an `.error` log sets the **error indicator** flag on the project dashboard.
    case error

    /// User-facing messages or chat/conversation events. Use for tracking
    /// what messages users send or receive within the app.
    case messages
}
