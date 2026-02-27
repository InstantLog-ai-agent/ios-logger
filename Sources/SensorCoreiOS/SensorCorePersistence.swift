import Foundation

// MARK: - SensorCorePersistence

/// Disk-backed buffer for log entries that failed to send due to network errors.
///
/// ## Design
///
/// ```
/// Network error
///      │
///      ▼
///  save([entry])  ──▶  Library/Caches/SensorCore/pending.jsonl
///                                       │
///      ┌────────────────────────────────┘
///      ▼
///  loadPending()  ──▶  [SensorCoreEntry]  (pruned: stale + over-cap)
///      │
///      ▼
///  flushPending()  ──▶  retry transmit()
///      │
///      ├── success → entry removed from file
///      └── failure → retryCount += 1, kept in file
/// ```
///
/// ## Thread Safety
/// All disk I/O is serialised on a dedicated `DispatchQueue`. The public API
/// methods are synchronous — they block the caller briefly while the I/O completes.
/// This is acceptable because all callers are background tasks, never the main thread.
///
/// ## File Format
/// [JSON Lines](https://jsonlines.org) — one ``SensorCoreEntry`` JSON object per line.
/// This format is append-friendly and crash-resilient: if the app crashes mid-write,
/// at most one line is corrupted; all previous entries remain intact.
final class SensorCorePersistence: @unchecked Sendable {

    // MARK: - Properties

    /// Serial queue that protects all file system access.
    private let queue = DispatchQueue(label: "com.sensorcore.persistence", qos: .utility)

    /// Encoder used to serialise entries to JSON (one per line).
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [] // compact, no pretty-print — one line per entry
        return e
    }()

    /// Decoder used to read entries back from disk.
    private let decoder = JSONDecoder()

    /// Maximum number of entries to keep on disk. Oldest are dropped when exceeded.
    private let maxEntries: Int

    /// Maximum age (seconds) for a pending entry. Older entries are pruned on load.
    private let maxAge: TimeInterval

    /// Path to the JSON-lines file: `Library/Caches/SensorCore/pending.jsonl`
    let fileURL: URL

    // MARK: - Init

    /// Creates a persistence manager.
    ///
    /// - Parameters:
    ///   - maxEntries: Disk cap for pending entries (from ``SensorCoreConfig/maxPendingLogs``).
    ///   - maxAge: Staleness threshold in seconds (from ``SensorCoreConfig/pendingLogMaxAge``).
    ///   - directory: Override for the persistence directory (useful for testing).
    init(maxEntries: Int = 500, maxAge: TimeInterval = 86400, directory: URL? = nil) {
        self.maxEntries = maxEntries
        self.maxAge = maxAge

        let dir: URL
        if let directory {
            dir = directory
        } else {
            // Library/Caches/SensorCore/ — no permissions needed, not backed up to iCloud,
            // and iOS may purge it under extreme storage pressure (acceptable for us).
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            dir = caches.appendingPathComponent("SensorCore", isDirectory: true)
        }

        self.fileURL = dir.appendingPathComponent("pending.jsonl")

        // Ensure the directory exists. This is a one-time cost at SDK startup.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Appends failed log entries to the persistence file.
    ///
    /// - Parameter entries: The entries that failed to transmit.
    func save(_ entries: [SensorCoreEntry]) {
        guard !entries.isEmpty else { return }
        queue.sync {
            _save(entries)
        }
    }

    /// Loads all pending entries from disk, pruning stale and over-cap entries.
    ///
    /// - Returns: An array of entries ready for retry, ordered oldest-first.
    func loadPending() -> [SensorCoreEntry] {
        queue.sync {
            _loadPending()
        }
    }

    /// Replaces the persistence file with the given entries.
    ///
    /// Used after a flush attempt to write back only the entries that still failed.
    ///
    /// - Parameter entries: Remaining entries. If empty, the file is deleted.
    func replacePending(_ entries: [SensorCoreEntry]) {
        queue.sync {
            _replacePending(entries)
        }
    }

    /// Deletes the persistence file entirely.
    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Returns the number of pending entries on disk.
    var pendingCount: Int {
        loadPending().count
    }

    // MARK: - Private Implementation

    /// Appends entries as JSON-lines to the file (creates if missing).
    private func _save(_ entries: [SensorCoreEntry]) {
        var lines = ""
        for entry in entries {
            guard let data = try? encoder.encode(entry),
                  let jsonString = String(data: data, encoding: .utf8) else {
                continue
            }
            lines += jsonString + "\n"
        }
        guard !lines.isEmpty else { return }
        guard let lineData = lines.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            // Append to existing file
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(lineData)
                handle.closeFile()
            }
        } else {
            // Create new file
            try? lineData.write(to: fileURL, options: .atomic)
        }
    }

    /// Reads, parses, prunes, and returns pending entries.
    private func _loadPending() -> [SensorCoreEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entries: [SensorCoreEntry] = []

        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(SensorCoreEntry.self, from: lineData) else {
                // Corrupted line — skip silently
                continue
            }

            // Prune: too many retries
            guard entry.retryCount < 3 else { continue }

            // Prune: stale entries
            if let entryDate = formatter.date(from: entry.created_at) {
                let age = now.timeIntervalSince(entryDate)
                if age > maxAge { continue }
            }

            entries.append(entry)
        }

        // Prune: over disk cap — keep newest, drop oldest
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }

        return entries
    }

    /// Overwrites the file with only the given entries, or deletes it if empty.
    private func _replacePending(_ entries: [SensorCoreEntry]) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        var lines = ""
        for entry in entries {
            guard let data = try? encoder.encode(entry),
                  let jsonString = String(data: data, encoding: .utf8) else {
                continue
            }
            lines += jsonString + "\n"
        }
        guard let lineData = lines.data(using: .utf8) else { return }
        try? lineData.write(to: fileURL, options: .atomic)
    }
}
