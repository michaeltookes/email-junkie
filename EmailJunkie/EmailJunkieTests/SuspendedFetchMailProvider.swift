import EmailJunkieMail
import XCTest

final class SuspendedFetchMailProvider: MailProvider, @unchecked Sendable {
    let didStartFetch = XCTestExpectation(description: "mail fetch started")
    private let lock = NSLock()
    private var fetchContinuation: CheckedContinuation<[MailMessage], Error>?

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            fetchContinuation = continuation
            lock.unlock()
            didStartFetch.fulfill()
        }
    }

    func completeFetch(with result: Result<[MailMessage], Error>) {
        lock.lock()
        let continuation = fetchContinuation
        fetchContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
