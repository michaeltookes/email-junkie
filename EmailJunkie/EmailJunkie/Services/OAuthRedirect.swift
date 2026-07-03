import AppKit
import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "OAuthRedirect")

/// Opens a URL in the user's default browser.
protocol BrowserOpening {
    func open(_ url: URL)
}

/// Production browser opener backed by `NSWorkspace`.
struct NSWorkspaceBrowserOpener: BrowserOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Listens for the OAuth redirect and returns its query parameters.
protocol RedirectListener {
    /// Starts listening and returns the loopback redirect URI to register.
    func start() async throws -> String
    /// Waits for the browser redirect and returns its query parameters.
    func waitForRedirect() async throws -> [String: String]
    /// Stops listening and releases the port.
    func stop()
}

/// A loopback (`127.0.0.1`) HTTP listener for the installed-app PKCE redirect.
///
/// The query-parsing is factored out as a pure static function and unit-tested;
/// the socket handling itself is verified live.
final class LoopbackRedirectListener: RedirectListener {

    private let queue = DispatchQueue(label: "com.tookes.EmailJunkie.loopback")
    private var listener: NWListener?
    private var hasResumed = false

    func start() async throws -> String {
        let listener = try NWListener(using: .tcp)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            func finish(_ result: Result<String, Error>) {
                guard !didResume else { return }
                didResume = true
                listener.stateUpdateHandler = nil
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        finish(.success(Self.redirectURI(forPort: port)))
                    } else {
                        finish(.failure(OAuthError.invalidResponse))
                    }
                case .failed(let error):
                    finish(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    static func redirectURI(forPort port: UInt16) -> String {
        "http://127.0.0.1:\(port)"
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection, continuation: continuation)
            }
        }
    }

    private func handle(
        connection: NWConnection,
        continuation: CheckedContinuation<[String: String], Error>
    ) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let params = Self.parseQuery(fromRequestLine: request)

            self.respond(on: connection)

            // Ignore incidental requests (e.g. favicon) that carry no result.
            guard params["code"] != nil || params["error"] != nil else { return }
            guard !self.hasResumed else { return }
            self.hasResumed = true
            continuation.resume(returning: params)
        }
    }

    private func respond(on connection: NWConnection) {
        let body = "Email Junkie is connected. You can close this window and return to the app."
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Parses query parameters from the first line of an HTTP request, e.g.
    /// `GET /?code=abc&state=xyz HTTP/1.1`.
    static func parseQuery(fromRequestLine request: String) -> [String: String] {
        let lines = request.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
        guard let firstLine = lines.first else { return [:] }
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2 else { return [:] }
        guard let components = URLComponents(string: "http://127.0.0.1\(fields[1])") else { return [:] }
        return (components.queryItems ?? []).reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }
}
