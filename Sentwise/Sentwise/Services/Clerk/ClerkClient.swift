import Foundation

/// One HTTP response from the Clerk Frontend API, including headers (we need the
/// rotated `Authorization` client token that Clerk returns on every response).
struct ClerkHTTPResponse: Sendable {
    let statusCode: Int
    /// Header fields with lowercased names.
    let headers: [String: String]
    let body: Data

    var isSuccess: Bool { (200..<300).contains(statusCode) }
    var clientToken: String? {
        guard let raw = headers["authorization"], !raw.isEmpty else { return nil }
        if raw.lowercased().hasPrefix("bearer ") {
            return String(raw.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }
}

/// A form-POST transport for the Clerk Frontend API. Split from the LLM/mail
/// transports because Clerk needs `application/x-www-form-urlencoded` bodies and,
/// crucially, exposes the response headers (for the rotating client token). Kept
/// as a protocol so `ClerkClient` is unit-testable against a fake.
protocol ClerkHTTPTransport: Sendable {
    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse
}

/// Production `ClerkHTTPTransport` over `URLSession`.
struct ClerkURLSessionTransport: ClerkHTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postForm(_ url: URL, headers: [String: String], form: [String: String]) async throws -> ClerkHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = Self.encodeForm(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        var lowered: [String: String] = [:]
        for (key, value) in (http?.allHeaderFields ?? [:]) {
            if let name = key as? String, let stringValue = value as? String {
                lowered[name.lowercased()] = stringValue
            }
        }
        return ClerkHTTPResponse(statusCode: statusCode, headers: lowered, body: data)
    }

    static func encodeForm(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Results

/// A started email-code sign-in (or first-time sign-up) awaiting the user's OTP.
struct ClerkSignInHandle: Sendable, Equatable {
    /// Which Clerk flow produced this handle. A brand-new email has no Clerk user
    /// yet, so it goes through `sign_ups`; an existing one through `sign_ins`. The
    /// user experience (enter email → enter code) is identical either way.
    enum Flow: Sendable, Equatable { case signIn, signUp }

    /// The `sign_in` id (`.signIn`) or `sign_up` id (`.signUp`).
    let signInId: String
    let emailAddressId: String
    /// The latest device/client token, to be carried into the verify call.
    let clientToken: String
    var flow: Flow = .signIn
}

/// A completed sign-in: the created session plus the latest client token.
struct ClerkVerifiedSession: Sendable, Equatable {
    let sessionId: String
    let clientToken: String
}

/// A freshly minted, short-lived session JWT plus the latest client token.
struct ClerkMintedToken: Sendable, Equatable {
    let jwt: String
    let clientToken: String
}

enum ClerkError: Error, Equatable, Sendable {
    /// Transport failure (offline, DNS, TLS).
    case transport(String)
    /// The API returned a non-2xx with an optional user-facing message.
    case http(status: Int, message: String?, clientToken: String? = nil)
    /// A required field was missing from an otherwise-2xx response.
    case malformedResponse(String)
    /// The sign-in didn't reach `complete` (e.g. needs a second factor we don't
    /// support in 56a).
    case notComplete(status: String?, missingFields: [String] = [], clientToken: String? = nil)
    /// No `email_code` first factor is available for this identifier.
    case emailCodeUnsupported
    /// Clerk has no user for this email (`form_identifier_not_found`); the caller
    /// falls back to the sign-up flow.
    case accountNotFound

    var clientToken: String? {
        switch self {
        case .http(_, _, let clientToken), .notComplete(_, _, let clientToken):
            return clientToken
        default:
            return nil
        }
    }
}

/// A minimal native client for Clerk's Frontend API email-code sign-in.
///
/// Implements Clerk's native (non-browser) mechanism: every request carries an
/// `Authorization: Bearer <clientToken>` header (empty on the very first call);
/// Clerk returns a rotated client token in the `Authorization` response header,
/// which the caller stores and echoes on the next call. No `Origin` header is
/// sent (that would put Clerk into browser mode). Google/OAuth sign-in is out of
/// scope for 56a — email code is the enabled primary method. See
/// `docs/managed-inference.md` for the rationale and live-verification note.
struct ClerkClient: Sendable {
    let frontendAPIBaseURL: URL
    let transport: ClerkHTTPTransport

    /// Clerk's default dev instance for Sentwise (peaceful-eel-9660).
    static let defaultFrontendAPIBaseURLString = "https://peaceful-eel-9660.clerk.accounts.dev"

    init(
        frontendAPIBaseURL: URL = URL(string: ClerkClient.defaultFrontendAPIBaseURLString)!,
        transport: ClerkHTTPTransport = ClerkURLSessionTransport()
    ) {
        self.frontendAPIBaseURL = frontendAPIBaseURL
        self.transport = transport
    }

    /// Starts an email-code sign-in and triggers the OTP email. Returns a handle
    /// the caller passes to `verifyEmailCode`.
    func sendEmailCode(email: String, clientToken: String) async throws -> ClerkSignInHandle {
        // 1. Create the sign-in with the email identifier. A first-time user has
        //    no Clerk account yet, which Clerk reports as `form_identifier_not_found`;
        //    in that case create the account via the sign-up flow instead.
        let created = try await post(
            path: "v1/client/sign_ins",
            form: ["identifier": email],
            clientToken: clientToken
        )
        let createdResource: SignInResource
        do {
            createdResource = try Self.decodeSignIn(
                created.body,
                status: created.statusCode,
                clientToken: created.clientToken
            )
        } catch ClerkError.accountNotFound {
            return try await startSignUp(email: email, clientToken: created.clientToken ?? clientToken)
        }
        var token = created.clientToken ?? clientToken

        guard let signInId = createdResource.id else {
            throw ClerkError.malformedResponse("sign_in id missing")
        }
        guard let emailAddressId = createdResource.supportedFirstFactors?
            .first(where: { $0.strategy == "email_code" })?.emailAddressId
        else {
            throw ClerkError.emailCodeUnsupported
        }

        // 2. Prepare the first factor → sends the code email.
        let prepared = try await post(
            path: "v1/client/sign_ins/\(signInId)/prepare_first_factor",
            form: ["strategy": "email_code", "email_address_id": emailAddressId],
            clientToken: token
        )
        _ = try Self.decodeSignIn(
            prepared.body,
            status: prepared.statusCode,
            clientToken: prepared.clientToken
        )
        token = prepared.clientToken ?? token

        return ClerkSignInHandle(signInId: signInId, emailAddressId: emailAddressId, clientToken: token)
    }

    /// First-time users: create a Clerk account for the email and send the
    /// verification code. Mirrors `sendEmailCode` but over Clerk's `sign_ups`
    /// resource (`create` → `prepare_verification`).
    private func startSignUp(email: String, clientToken: String) async throws -> ClerkSignInHandle {
        let created = try await post(
            path: "v1/client/sign_ups",
            form: ["email_address": email],
            clientToken: clientToken
        )
        let createdResource = try Self.decodeSignIn(
            created.body,
            status: created.statusCode,
            clientToken: created.clientToken
        )
        var token = created.clientToken ?? clientToken
        guard let signUpId = createdResource.id else {
            throw ClerkError.malformedResponse("sign_up id missing")
        }

        let prepared = try await post(
            path: "v1/client/sign_ups/\(signUpId)/prepare_verification",
            form: ["strategy": "email_code"],
            clientToken: token
        )
        _ = try Self.decodeSignIn(
            prepared.body,
            status: prepared.statusCode,
            clientToken: prepared.clientToken
        )
        token = prepared.clientToken ?? token

        return ClerkSignInHandle(signInId: signUpId, emailAddressId: "", clientToken: token, flow: .signUp)
    }

    /// Submits the OTP code, completing the sign-in (or sign-up) and yielding a
    /// session id.
    func verifyEmailCode(
        signInId: String,
        code: String,
        clientToken: String,
        flow: ClerkSignInHandle.Flow = .signIn
    ) async throws -> ClerkVerifiedSession {
        let path: String
        switch flow {
        case .signIn: path = "v1/client/sign_ins/\(signInId)/attempt_first_factor"
        case .signUp: path = "v1/client/sign_ups/\(signInId)/attempt_verification"
        }
        let attempted = try await post(
            path: path,
            form: ["strategy": "email_code", "code": code],
            clientToken: clientToken
        )
        let token = attempted.clientToken ?? clientToken
        let resource = try Self.decodeSignIn(
            attempted.body,
            status: attempted.statusCode,
            clientToken: token
        )

        guard resource.status == "complete", let sessionId = resource.createdSessionId else {
            throw ClerkError.notComplete(
                status: resource.status,
                missingFields: resource.missingFields ?? [],
                clientToken: token
            )
        }
        return ClerkVerifiedSession(sessionId: sessionId, clientToken: token)
    }

    /// Mints a fresh, short-lived session JWT for the given session. This is the
    /// token the `sentwise-service` Worker verifies. Refresh by calling again.
    func mintSessionToken(sessionId: String, clientToken: String) async throws -> ClerkMintedToken {
        let response = try await post(
            path: "v1/client/sessions/\(sessionId)/tokens",
            form: [:],
            clientToken: clientToken
        )
        guard response.isSuccess else {
            throw ClerkError.http(
                status: response.statusCode,
                message: Self.firstErrorMessage(response.body),
                clientToken: response.clientToken
            )
        }
        let decoded = try? JSONDecoder().decode(TokenEnvelope.self, from: response.body)
        guard let jwt = decoded?.jwt, !jwt.isEmpty else {
            throw ClerkError.malformedResponse("session token jwt missing")
        }
        return ClerkMintedToken(jwt: jwt, clientToken: response.clientToken ?? clientToken)
    }

    // MARK: - Internals

    private func post(path: String, form: [String: String], clientToken: String) async throws -> ClerkHTTPResponse {
        let url = Self.buildURL(base: frontendAPIBaseURL, path: path)
        // Native mode: send the Authorization header (never an Origin header).
        let headers = ["authorization": "Bearer \(clientToken)"]
        do {
            return try await transport.postForm(url, headers: headers, form: form)
        } catch {
            throw ClerkError.transport(String(describing: error))
        }
    }

    static func buildURL(base: URL, path: String) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        // Mark the request as native so Clerk uses header-token auth, not cookies.
        components?.queryItems = [URLQueryItem(name: "_is_native", value: "1")]
        return components?.url ?? base.appendingPathComponent(path)
    }

    private static func decodeSignIn(_ data: Data, status: Int, clientToken: String? = nil) throws -> SignInResource {
        let envelope = try? JSONDecoder().decode(SignInEnvelope.self, from: data)
        guard (200..<300).contains(status) else {
            if envelope?.errors?.contains(where: { $0.code == "form_identifier_not_found" }) == true {
                throw ClerkError.accountNotFound
            }
            throw ClerkError.http(
                status: status,
                message: envelope?.errors?.first?.longMessage
                    ?? envelope?.errors?.first?.message
                    ?? firstErrorMessage(data),
                clientToken: clientToken
            )
        }
        guard let resource = envelope?.response else {
            throw ClerkError.malformedResponse("missing response object")
        }
        return resource
    }

    private static func firstErrorMessage(_ data: Data) -> String? {
        let envelope = try? JSONDecoder().decode(ErrorsEnvelope.self, from: data)
        return envelope?.errors?.first?.longMessage ?? envelope?.errors?.first?.message
    }
}

// MARK: - Wire-format DTOs (file-private)

private struct SignInEnvelope: Decodable {
    let response: SignInResource?
    let errors: [ClerkAPIError]?
}

private struct SignInResource: Decodable {
    let id: String?
    let status: String?
    let createdSessionId: String?
    let supportedFirstFactors: [FirstFactor]?
    /// Sign-up only: fields Clerk still requires (e.g. `password` when the
    /// instance is misconfigured for a passwordless product).
    let missingFields: [String]?

    enum CodingKeys: String, CodingKey {
        case id, status
        case createdSessionId = "created_session_id"
        case supportedFirstFactors = "supported_first_factors"
        case missingFields = "missing_fields"
    }
}

private struct FirstFactor: Decodable {
    let strategy: String?
    let emailAddressId: String?

    enum CodingKeys: String, CodingKey {
        case strategy
        case emailAddressId = "email_address_id"
    }
}

private struct TokenEnvelope: Decodable {
    let jwt: String?
}

private struct ErrorsEnvelope: Decodable {
    let errors: [ClerkAPIError]?
}

private struct ClerkAPIError: Decodable {
    let message: String?
    let longMessage: String?
    let code: String?

    enum CodingKeys: String, CodingKey {
        case message
        case longMessage = "long_message"
        case code
    }
}
