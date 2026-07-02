import Foundation

/// A minimal HTTP response used by the OAuth services.
struct HTTPResponse: Equatable {
    let statusCode: Int
    let body: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Abstraction over the network so OAuth logic can be tested without live calls.
protocol HTTPTransport {
    /// Sends an `application/x-www-form-urlencoded` POST and returns the response.
    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse
}

/// `URLSession`-backed transport used in production.
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postForm(_ url: URL, fields: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(statusCode: statusCode, body: data)
    }

    /// Percent-encodes fields for form submission, encoding reserved characters
    /// like `+`, `/`, and `=` that appear in OAuth codes and tokens.
    static func formEncode(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let body = fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}
