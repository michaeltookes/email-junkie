import Foundation

/// Opt-in, append-only diagnostic log for IMAP operations.
///
/// Off unless the `EMAILJUNKIE_IMAP_LOG` environment variable points to a file
/// path, so it costs nothing and leaks nothing in normal use. Used to reproduce
/// the large-mailbox bulk under-selection (item 49) against a real server, where
/// unit tests with a well-behaved fake cannot: it records, per selection window,
/// how many messages the server's `SEARCH` returned versus how many we resolved
/// to UIDs, which distinguishes a server-side partial result from a client-side
/// drop.
enum IMAPDiagnosticLog {
    /// The log file path, or `nil` when logging is disabled.
    static var path: String? {
        ProcessInfo.processInfo.environment["EMAILJUNKIE_IMAP_LOG"]
    }

    /// Whether diagnostic logging is currently enabled.
    static var isEnabled: Bool { path != nil }

    private static let lock = NSLock()

    /// Appends one line (timestamp prefixed) to the log file when enabled.
    /// Never throws — diagnostics must not affect the operation being observed.
    static func log(_ message: @autoclosure () -> String) {
        guard let path else { return }
        let line = "\(Self.timestamp) \(message())\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static var timestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
