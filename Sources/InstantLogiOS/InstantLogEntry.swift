import Foundation

// MARK: - InstantLogEntry

/// Internal JSON-encodable representation of a single log entry.
///
/// Instances are created by ``InstantLog`` and passed to ``InstantLogClient``
/// for queuing and transmission. This type is intentionally internal — consumers
/// of the SDK interact only through ``InstantLog/log(_:level:userId:metadata:)``.
struct InstantLogEntry: Encodable {

    // MARK: - Stored properties (match server field names exactly)

    /// The log message text. Already truncated to 200 characters by the time
    /// this struct is created.
    let content: String

    /// Raw string value of ``InstantLogLevel``, e.g. `"info"`, `"error"`.
    let level: String

    /// External user identifier, if provided. Snake-cased to match the server field name.
    let user_id: String?

    /// Key-value metadata encoded as ``InstantLogMetadataValue`` wrappers.
    /// `nil` when the caller did not supply a metadata dict.
    let metadata: [String: InstantLogMetadataValue]?

    // MARK: - Init

    /// Creates a log entry from the SDK's public-facing parameters.
    ///
    /// During initialisation, unsupported metadata value types are silently dropped
    /// (see ``InstantLogMetadataValue``).
    ///
    /// - Parameters:
    ///   - content: Already-truncated log message.
    ///   - level: Severity level; stored as `rawValue` string.
    ///   - userId: Optional user identifier.
    ///   - metadata: Raw dictionary; values are converted to ``InstantLogMetadataValue``.
    init(
        content: String,
        level: InstantLogLevel,
        userId: String?,
        metadata: [String: Any]?
    ) {
        self.content = content
        self.level = level.rawValue
        self.user_id = userId
        self.metadata = metadata.map { dict in
            dict.compactMapValues { InstantLogMetadataValue(value: $0) }
        }
    }
}

// MARK: - InstantLogMetadataValue

/// Type-erasing wrapper that makes heterogeneous metadata dictionaries `Encodable`.
///
/// The server accepts a flat JSON object for `metadata`. Swift's type system
/// requires all values in a `Codable` dictionary to be the same type, so this enum
/// wraps each supported primitive before encoding.
///
/// ### Supported types
/// | Swift type | JSON type |
/// |-----------|-----------|
/// | `String`  | string    |
/// | `Int`     | number    |
/// | `Double` / `Float` | number |
/// | `Bool`    | boolean   |
///
/// Any other type (arrays, nested dictionaries, custom objects) is silently ignored
/// by ``init?(value:)`` returning `nil`, which causes `compactMapValues` to drop the key.
enum InstantLogMetadataValue: Encodable {

    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    // MARK: - Init

    /// Attempts to wrap a raw `Any` value.
    ///
    /// Returns `nil` for unsupported types so callers can use `compactMapValues`.
    ///
    /// - Parameter value: The raw value from the user-supplied metadata dictionary.
    init?(value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as Int:    self = .int(v)
        case let v as Double: self = .double(v)
        case let v as Float:  self = .double(Double(v))
        case let v as Bool:   self = .bool(v)
        default:              return nil
        }
    }

    // MARK: - Encodable

    /// Encodes the wrapped value as a JSON primitive into a single-value container.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v):   try container.encode(v)
        }
    }
}
