import Foundation

// MARK: - InstantLogError

/// Errors thrown by ``InstantLog/logAsync(_:level:userId:metadata:)``.
///
/// For fire-and-forget calls via ``InstantLog/log(_:level:userId:metadata:)``
/// these errors are swallowed internally and printed to the console in `DEBUG` builds only.
///
/// ### Handling errors
/// ```swift
/// do {
///     try await InstantLog.logAsync("Purchase failed", level: .error)
/// } catch let error as InstantLogError {
///     switch error {
///     case .rateLimited:            // server banned this client — stop retrying
///     case .serverError(let code):  // e.g. 401 invalid API key, 500 server crash
///     case .networkError:           // timeout, no internet, etc.
///     case .notConfigured:          // forgot to call configure()
///     case .encodingFailed:         // metadata contained an un-serialisable type
///     }
/// }
/// ```
public enum InstantLogError: Error, LocalizedError {

    /// ``InstantLog/logAsync(_:level:userId:metadata:)`` was called before
    /// ``InstantLog/configure(apiKey:host:defaultUserId:enabled:timeout:)``.
    case notConfigured

    /// The ``InstantLogEntry`` could not be serialised to JSON.
    /// This usually means a metadata value contained an unsupported type
    /// that slipped past ``InstantLogMetadataValue/init?(value:)``.
    case encodingFailed(Error)

    /// The server responded with a non-2xx HTTP status code other than 429.
    ///
    /// Common causes:
    /// - `401` — invalid or missing API key
    /// - `400` — request body failed server-side validation (e.g. `content` too long)
    /// - `500` — internal server error
    case serverError(statusCode: Int)

    /// A transport-level error occurred before a response was received.
    ///
    /// Common causes: no internet connection, request timeout, DNS failure.
    case networkError(Error)

    /// The server returned **HTTP 429** (Too Many Requests).
    ///
    /// The SDK has activated its circuit-breaker and will discard all future
    /// log calls for the remainder of the app session. No further network
    /// requests will be made until the app is relaunched.
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .notConfigured:          return "InstantLog is not configured. Call InstantLog.configure(...) at app startup."
        case .encodingFailed(let e):  return "Failed to encode log entry: \(e.localizedDescription)"
        case .serverError(let code):  return "Server returned HTTP \(code)"
        case .networkError(let e):    return "Network error: \(e.localizedDescription)"
        case .rateLimited:            return "InstantLog rate-limited (HTTP 429). Logging suspended for this session."
        }
    }
}

// MARK: - InstantLogClient

/// Internal actor that owns the log queue and all network I/O.
///
/// ## Architecture
///
/// ```
///  log()          logAsync()
///    │                │
///    ▼                ▼
/// enqueue()      sendThrowing()   ← bypasses queue, async/throws
///    │
///    ▼
/// AsyncStream<InstantLogEntry>     ← bounded FIFO queue (max 1 000 entries)
///    │
///    ▼
/// single consumer Task             ← one Task for the lifetime of the client
///    │
///    ▼
/// transmit() → URLSession → server
///                              │
///                         429? → silence() → stream.finish() → Task exits
/// ```
///
/// ## Thread safety
/// - The actor serialises all internal state access.
/// - `enqueue()` and `_isSilenced` are `nonisolated` for synchronous call-site use.
/// - The consumer Task captures only `Sendable` values — no reference to `self` is retained
///   (except weakly) so the actor can be released when the SDK is re-configured.
actor InstantLogClient {

    // MARK: - Constants

    /// Maximum number of log entries that can be pending in the queue.
    /// When this limit is reached, **new** entries are dropped (oldest are preserved).
    static let queueCapacity = 1_000

    // MARK: - Private state

    /// `URLSession` configured with the project's timeout value.
    private let session: URLSession

    /// Reusable encoder for serialising ``InstantLogEntry`` values to JSON.
    private let encoder: JSONEncoder

    /// API key sent in the `x-api-key` request header.
    private let apiKey: String

    /// Server base URL. The path `/api/logs` is appended by ``buildRequest(entry:)``.
    private let host: URL

    /// The write end of the internal ``AsyncStream``.
    /// Calling `.finish()` on it signals the consumer Task to exit gracefully.
    private let continuation: AsyncStream<InstantLogEntry>.Continuation

    /// Circuit-breaker flag.
    ///
    /// Once set to `true` (on HTTP 429), it is never reset during the current session.
    /// Declared `nonisolated(unsafe)` so ``enqueue(_:)`` can read it without `await`.
    /// Safe because the transition `false → true` happens exactly once, from the
    /// sequential consumer Task, and a stale `false` read by `enqueue` at worst
    /// causes one extra `yield` that the already-finished stream will silently drop.
    nonisolated(unsafe) private var _isSilenced: Bool = false

    // MARK: - Init

    /// Creates a new client and immediately starts the background consumer Task.
    ///
    /// - Parameter config: The SDK configuration containing API key, host, and timeout.
    init(config: InstantLogConfig) {
        let sessionCfg = URLSessionConfiguration.default
        sessionCfg.timeoutIntervalForRequest = config.timeout
        let session = URLSession(configuration: sessionCfg)
        self.session = session

        let encoder = JSONEncoder()
        self.encoder = encoder
        self.apiKey = config.apiKey
        self.host = config.host

        // Build the bounded FIFO stream. The continuation's `yield` is Sendable,
        // so it can be called from any thread / actor.
        var cont: AsyncStream<InstantLogEntry>.Continuation!
        let stream = AsyncStream<InstantLogEntry>(
            bufferingPolicy: .bufferingOldest(InstantLogClient.queueCapacity)
        ) { cont = $0 }
        self.continuation = cont

        // Start the single consumer. `[weak self]` prevents a permanent reference
        // cycle — if this actor is released (e.g. after re-configure) the Task
        // will exit on the next loop iteration.
        Task.detached(priority: .utility) { [weak self] in
            for await entry in stream {
                guard let self else { break }
                let banned = await self.transmit(entry: entry)
                if banned { break }
            }
        }
    }

    // MARK: - Internal API

    /// Pushes a log entry into the queue. **Synchronous and nonisolated.**
    ///
    /// This method returns immediately without ever suspending — it is safe to
    /// call from `@MainActor` or any synchronous context with no performance impact.
    ///
    /// If the circuit-breaker has been triggered (``InstantLogError/rateLimited``),
    /// the entry is silently dropped before it even reaches the stream.
    ///
    /// - Parameter entry: The pre-built log entry to enqueue.
    nonisolated func enqueue(_ entry: InstantLogEntry) {
        guard !_isSilenced else { return }   // fast-path: no actor hop, no await
        continuation.yield(entry)
    }

    /// Sends a log entry **directly**, bypassing the queue.
    ///
    /// Used exclusively by ``InstantLog/logAsync(_:level:userId:metadata:)`` when
    /// the caller needs to confirm that the server received the log.
    ///
    /// - Parameter entry: The log entry to transmit.
    /// - Throws: ``InstantLogError/rateLimited`` if already silenced;
    ///   ``InstantLogError/networkError(_:)`` on transport failure;
    ///   ``InstantLogError/serverError(statusCode:)`` on non-2xx response.
    func sendThrowing(entry: InstantLogEntry) async throws {
        guard !_isSilenced else { throw InstantLogError.rateLimited }
        let request = try buildRequest(entry: entry)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw InstantLogError.networkError(error)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                silence()
                throw InstantLogError.rateLimited
            }
            if !(200...299).contains(http.statusCode) {
                throw InstantLogError.serverError(statusCode: http.statusCode)
            }
        }
    }

    // MARK: - Private

    /// Sends one entry from the queue. Called by the consumer Task in a serial loop.
    ///
    /// - Parameter entry: The next entry dequeued from the `AsyncStream`.
    /// - Returns: `true` if a 429 was received and the consumer should stop; `false` otherwise.
    private func transmit(entry: InstantLogEntry) async -> Bool {
        guard !_isSilenced else { return true }
        guard let request = try? buildRequest(entry: entry) else {
            #if DEBUG
            print("[InstantLog] 🔇 Failed to encode log entry — skipping.")
            #endif
            return false
        }
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 {
                    silence()
                    return true   // signal the consumer loop to break
                }
                if !(200...299).contains(http.statusCode) {
                    #if DEBUG
                    print("[InstantLog] ❌ Server error \(http.statusCode) — log dropped.")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            print("[InstantLog] ❌ Network error: \(error.localizedDescription)")
            #endif
        }
        return false
    }

    /// Activates the circuit-breaker.
    ///
    /// Sets `_isSilenced = true`, finishes the stream (which causes the consumer
    /// Task to exit after draining), and prints a warning in DEBUG builds.
    /// This method is idempotent — calling it more than once is harmless.
    private func silence() {
        _isSilenced = true
        continuation.finish()   // gracefully stops the consumer Task
        #if DEBUG
        print("[InstantLog] ⚠️ HTTP 429 — rate limited by server. Logging suspended for this session.")
        #endif
    }

    /// Builds a `POST /api/logs` request with the correct headers and JSON body.
    ///
    /// - Parameter entry: The entry to serialise as the request body.
    /// - Returns: A ready-to-send `URLRequest`.
    /// - Throws: ``InstantLogError/encodingFailed(_:)`` if JSON encoding fails.
    private func buildRequest(entry: InstantLogEntry) throws -> URLRequest {
        let url = host.appendingPathComponent("api/logs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        do {
            request.httpBody = try encoder.encode(entry)
        } catch {
            // Preserve the real encoding error so callers can surface it via InstantLogError.encodingFailed.
            throw InstantLogError.encodingFailed(error)
        }
        return request
    }
}
