import EmailJunkieMail
import Foundation

final class PrefixMailProvider: MailProvider, @unchecked Sendable {
    private let messages: [MailMessage]
    private(set) var fetchLimits: [Int] = []
    private(set) var bodyFetchCallCount = 0

    init(messages: [MailMessage]) {
        self.messages = messages
    }

    func verifyConnection(_ credentials: MailAccountCredentials) async throws {}

    func fetchRecentMessages(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        limit: Int
    ) async throws -> [MailMessage] {
        fetchLimits.append(limit)
        return Array(messages.prefix(limit))
    }

    func fetchBodyText(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32?
    ) async throws -> Data {
        bodyFetchCallCount += 1
        return Data("Please advise.".utf8)
    }

    func appendMessage(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        rfc822: Data,
        flags: [MailFlag]
    ) async throws {}
}
