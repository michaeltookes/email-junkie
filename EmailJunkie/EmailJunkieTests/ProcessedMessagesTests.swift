import EmailJunkieMail
import XCTest
@testable import EmailJunkie

final class ProcessedMessagesTests: XCTestCase {

    private func message(id: UInt32, messageID: String? = nil, uidValidity: UInt32? = nil) -> MailMessage {
        MailMessage(
            id: id,
            uidValidity: uidValidity,
            from: MailAddress(email: "a@x.com"),
            subject: "Hi",
            date: "",
            messageID: messageID
        )
    }

    func testKeyPrefersMessageID() {
        let key = ProcessedMessages.key(for: message(id: 5, messageID: "<abc@x.com>", uidValidity: 99))
        XCTAssertEqual(key, "mid:<abc@x.com>")
    }

    func testKeyFallsBackToUIDValidityAndUID() {
        let key = ProcessedMessages.key(for: message(id: 5, uidValidity: 99))
        XCTAssertEqual(key, "uid:99:5")
    }

    func testInsertAndContains() {
        var store = ProcessedMessages()
        let msg = message(id: 5, messageID: "<abc@x.com>")
        XCTAssertFalse(store.contains(msg))
        store.insert(msg)
        XCTAssertTrue(store.contains(msg))
    }

    func testSameMessageIDAcrossMailboxesIsRecognized() {
        var store = ProcessedMessages()
        store.insert(message(id: 5, messageID: "<abc@x.com>", uidValidity: 1))
        // Same Message-ID, different UID/UIDVALIDITY (e.g. moved mailbox).
        XCTAssertTrue(store.contains(message(id: 99, messageID: "<abc@x.com>", uidValidity: 2)))
    }

    func testInsertIsIdempotent() {
        var store = ProcessedMessages()
        let msg = message(id: 5, messageID: "<abc@x.com>")
        store.insert(msg)
        store.insert(msg)
        XCTAssertEqual(store.keys.count, 1)
    }

    func testEvictsOldestPastLimit() {
        var store = ProcessedMessages()
        for index in 0..<(ProcessedMessages.limit + 10) {
            store.insert(message(id: UInt32(index), messageID: "<\(index)@x.com>"))
        }
        XCTAssertEqual(store.keys.count, ProcessedMessages.limit)
        // The 10 oldest were evicted; the newest remain.
        XCTAssertFalse(store.contains(message(id: 0, messageID: "<0@x.com>")))
        XCTAssertTrue(store.contains(message(id: 5, messageID: "<\(ProcessedMessages.limit + 5)@x.com>")))
    }

    func testCodableRoundTrip() throws {
        var store = ProcessedMessages()
        store.insert(message(id: 1, messageID: "<1@x.com>"))
        store.insert(message(id: 2, messageID: "<2@x.com>"))

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ProcessedMessages.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertTrue(decoded.contains(message(id: 2, messageID: "<2@x.com>")))
    }

    func testDecodesMissingKeysAsEmpty() throws {
        let decoded = try JSONDecoder().decode(ProcessedMessages.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.keys.isEmpty)
    }
}
