import Foundation

/// Sends a JSON POST with arbitrary headers. LLM APIs need `application/json`
/// bodies and per-provider auth headers, which the form-encoded `HTTPTransport`
/// doesn't cover; this keeps the LLM layer injectable for tests without a live
/// network call.
protocol LLMHTTPTransport: Sendable {
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse
}

extension URLSessionTransport: LLMHTTPTransport {
    func postJSON(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(statusCode: statusCode, body: data)
    }
}
