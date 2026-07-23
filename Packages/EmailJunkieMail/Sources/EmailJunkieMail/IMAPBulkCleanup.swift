import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// The raw outcome of one bulk-cleanup connection, shaped into either a
/// `MailBulkPreview` or a `MailBulkResult` by the calling provider method.
struct IMAPBulkOutcome: Sendable, Equatable {
    /// How many messages the filter selected.
    var matchCount: Int
    /// Envelope sample of the newest matches (preview only; empty when applying).
    var sample: [MailMessage]
    /// True when selection stopped at the cap, so `matchCount` is a lower bound.
    var isPartial: Bool
    /// How many messages the action was actually applied to (0 for a preview).
    var affectedCount: Int
}

extension IMAPMailProvider {
    /// Default cap on how many messages one cleanup pass will select. Keeps a
    /// single operation bounded in time and memory on a mailbox with tens of
    /// thousands of matches; the user simply runs another pass to continue.
    public static var bulkSelectionCap: Int { 5_000 }

    /// Default number of matches shown in a preview.
    public static var bulkPreviewSampleSize: Int { 25 }

    /// Scans `mailbox` for messages matching `criteria` and reports what a bulk
    /// action *would* affect, without changing anything.
    ///
    /// Selection walks the mailbox in bounded sequence windows (see
    /// `SequenceWindow`), so the server never returns an unbounded `* SEARCH`
    /// line — the failure mode that breaks plain search on huge mailboxes
    /// (item 45).
    public func previewBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        sampleLimit: Int = IMAPMailProvider.bulkPreviewSampleSize,
        selectionCap: Int = IMAPMailProvider.bulkSelectionCap
    ) async throws -> MailBulkPreview {
        let outcome = try await runBulkCleanup(
            credentials,
            mailbox: mailbox,
            criteria: criteria,
            action: nil,
            sampleLimit: sampleLimit,
            selectionCap: selectionCap,
            onProgress: nil
        )
        return MailBulkPreview(
            matchCount: outcome.matchCount,
            sample: outcome.sample,
            isPartial: outcome.isPartial
        )
    }

    /// Applies `action` to every message in `mailbox` matching `criteria`.
    ///
    /// Selection completes before any change is made, so relocating messages
    /// cannot shift the sequence numbers the scan is still walking. The action
    /// then runs in bounded batches, reporting progress after each one.
    public func applyBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction,
        selectionCap: Int = IMAPMailProvider.bulkSelectionCap,
        onProgress: (@Sendable (MailBulkProgress) -> Void)? = nil
    ) async throws -> MailBulkResult {
        let outcome = try await runBulkCleanup(
            credentials,
            mailbox: mailbox,
            criteria: criteria,
            action: action,
            sampleLimit: 0,
            selectionCap: selectionCap,
            onProgress: onProgress
        )
        return MailBulkResult(action: action, affectedCount: outcome.affectedCount)
    }

    private func runBulkCleanup(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        criteria: MailSearchCriteria,
        action: MailBulkAction?,
        sampleLimit: Int,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?
    ) async throws -> IMAPBulkOutcome {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard selectionCap > 0 else {
            return IMAPBulkOutcome(matchCount: 0, sample: [], isPartial: false, affectedCount: 0)
        }

        let naming = credentials.mailboxNaming
        let mailboxName = mailbox.imapName(using: naming)
        let destinationName = action?.destination?.imapName(using: naming)

        // Moving a message into the folder it already lives in is a no-op at
        // best and a duplicate at worst — refuse rather than churn the mailbox.
        if let destinationName, destinationName == mailboxName {
            throw MailError.commandFailed(
                "The source and destination folders are the same (\(mailboxName))."
            )
        }

        let attempts = IMAPBulkCleanupAttempts()
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let host = credentials.host
        let email = credentials.email
        let password = credentials.appPassword

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let promise = attempts.makePromise(for: channel)
                    let handler = IMAPBulkCleanupHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        destinationName: destinationName,
                        criteria: criteria,
                        action: action,
                        sampleLimit: sampleLimit,
                        selectionCap: selectionCap,
                        onProgress: onProgress,
                        promise: promise
                    )
                    return channel.pipeline.addHandlers([ssl, IMAPClientHandler(), handler])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: credentials.host, port: credentials.port).get()
        } catch {
            throw MailError.connectionFailed(String(describing: error))
        }
        guard let outcomeFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start the cleanup.")
        }

        // A bulk pass walks many windows and batches, so it needs a longer
        // ceiling than a single request — but still a finite one.
        let deadline = channel.eventLoop.scheduleTask(in: .minutes(10)) {
            channel.close(promise: nil)
        }
        defer { deadline.cancel() }

        do {
            let outcome = try await outcomeFuture.get()
            try? await channel.close().get()
            return outcome
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Tracks bulk-cleanup futures per channel (mirrors the search/page trackers) so
/// Happy Eyeballs attempts can't settle the winning channel's result.
final class IMAPBulkCleanupAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var futures: [ObjectIdentifier: EventLoopFuture<IMAPBulkOutcome>] = [:]

    func makePromise(for channel: Channel) -> EventLoopPromise<IMAPBulkOutcome> {
        let promise = channel.eventLoop.makePromise(of: IMAPBulkOutcome.self)
        lock.lock()
        futures[ObjectIdentifier(channel)] = promise.futureResult
        lock.unlock()
        return promise
    }

    func future(for channel: Channel) -> EventLoopFuture<IMAPBulkOutcome>? {
        lock.lock()
        defer { lock.unlock() }
        return futures.removeValue(forKey: ObjectIdentifier(channel))
    }
}

/// Drives the bulk-cleanup conversation:
///
/// `LOGIN → SELECT → UID SEARCH (one bounded window at a time) → [sample FETCH |
/// UID STORE/MOVE in batches] → LOGOUT`
///
/// Selection is deliberately completed before any mutation: a `UID MOVE`
/// removes messages and renumbers the sequence space, which would corrupt a
/// scan still walking that space.
final class IMAPBulkCleanupHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private enum Step {
        case greeting, login, select, search, sample, apply, done
    }

    private struct PartialMessage {
        var uid: UInt32?
        var from: MailAddress?
        var replyTo: MailAddress?
        var hasEnvelope = false
        var subject = ""
        var date = ""
        var messageID: String?
    }

    private let email: String
    private let password: String
    private let mailboxName: String
    private let destinationName: String?
    private let criteria: MailSearchCriteria
    private let action: MailBulkAction?
    private let sampleLimit: Int
    private let selectionCap: Int
    private let onProgress: (@Sendable (MailBulkProgress) -> Void)?
    private let promise: EventLoopPromise<IMAPBulkOutcome>

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let sampleTag = "A3"
    private let logoutTag = "A4"

    private var step: Step = .greeting
    private var settled = false
    private var messageCount = 0
    private var selectedUIDValidity: UInt32?

    private var windows: [(lower: UInt32, upper: UInt32)] = []
    private var windowIndex = 0
    private var matchedUIDs: [UInt32] = []
    private var isPartial = false

    private var batches: [[UInt32]] = []
    private var batchIndex = 0
    private var affectedCount = 0

    private var sample: [MailMessage] = []
    private var current: PartialMessage?

    init(
        email: String,
        password: String,
        mailboxName: String,
        destinationName: String?,
        criteria: MailSearchCriteria,
        action: MailBulkAction?,
        sampleLimit: Int,
        selectionCap: Int,
        onProgress: (@Sendable (MailBulkProgress) -> Void)?,
        promise: EventLoopPromise<IMAPBulkOutcome>
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.destinationName = destinationName
        self.criteria = criteria
        self.action = action
        self.sampleLimit = sampleLimit
        self.selectionCap = selectionCap
        self.onProgress = onProgress
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .untagged(let payload):
            handleUntagged(payload, context: context)
        case .fetch(let fetchResponse):
            handleFetch(fetchResponse)
        case .tagged(let tagged):
            handleTagged(tagged, context: context)
        case .fatal(let text):
            settle(.failure(MailError.connectionFailed(text.text)))
            context.close(promise: nil)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle(.failure(Self.mapped(error)))
        context.close(promise: nil)
    }

    /// Windowed selection exists precisely so the 8 KB frame cap is never hit,
    /// but map it anyway: if a window ever did overflow, "narrow your filter" is
    /// far more useful than a raw decoder error (item 45).
    static func mapped(_ error: Error) -> MailError {
        if error is ByteToMessageDecoderError.PayloadTooLargeError {
            return .resultTooLarge
        }
        return .connectionFailed(String(describing: error))
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(MailError.connectionFailed("The connection closed before the cleanup completed.")))
        context.fireChannelInactive()
    }

    // MARK: - Response handling

    private func handleUntagged(_ payload: ResponsePayload, context: ChannelHandlerContext) {
        captureUIDValidity(from: payload)

        switch step {
        case .greeting:
            send(.login(username: email, password: password), tag: loginTag, context: context)
            step = .login
        case .select:
            if case .mailboxData(.exists(let count)) = payload {
                messageCount = count
            }
        case .search:
            if case .mailboxData(.search(let ids, _)) = payload {
                matchedUIDs.append(contentsOf: ids.map(\.rawValue))
            }
        default:
            break
        }
    }

    private func handleTagged(_ tagged: TaggedResponse, context: ChannelHandlerContext) {
        switch tagged.tag {
        case loginTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            send(.select(MailboxName(ByteBuffer(string: mailboxName))), tag: selectTag, context: context)
            step = .select
        case selectTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            captureUIDValidity(from: tagged.state)
            beginSelection(context: context)
        case sampleTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            settlePreview(context: context)
        default:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            if step == .search {
                windowIndex += 1
                continueSelection(context: context)
            } else if step == .apply {
                affectedCount += batches[batchIndex].count
                onProgress?(MailBulkProgress(processed: affectedCount, total: matchedUIDs.count))
                batchIndex += 1
                continueApply(context: context)
            }
        }
    }

    private func handleFetch(_ response: FetchResponse) {
        switch response {
        case .start:
            current = PartialMessage()
        case .simpleAttribute(let attribute):
            apply(attribute)
        case .finish:
            if let message = current, let uid = message.uid, message.hasEnvelope {
                sample.append(
                    MailMessage(
                        id: uid,
                        uidValidity: selectedUIDValidity,
                        from: message.from,
                        replyTo: message.replyTo,
                        subject: message.subject,
                        date: message.date,
                        messageID: message.messageID
                    )
                )
            }
            current = nil
        default:
            break
        }
    }

    private func apply(_ attribute: MessageAttribute) {
        switch attribute {
        case .uid(let uid):
            current?.uid = uid.rawValue
        case .envelope(let envelope):
            applyEnvelope(envelope)
        default:
            break
        }
    }

    private func applyEnvelope(_ envelope: Envelope) {
        guard current != nil else { return }
        current?.hasEnvelope = true
        if let subject = envelope.subject {
            current?.subject = String(buffer: subject)
        }
        if let date = envelope.date {
            current?.date = String(date)
        }
        if let sender = envelope.from.first, let address = Self.address(from: sender) {
            current?.from = address
        }
        if let replyTo = envelope.reply.first, let address = Self.address(from: replyTo) {
            current?.replyTo = address
        }
        if let messageID = envelope.messageID {
            current?.messageID = String(messageID)
        }
    }

    // MARK: - Selection

    private func beginSelection(context: ChannelHandlerContext) {
        windows = SequenceWindow.windows(total: messageCount)
        windowIndex = 0
        step = .search
        continueSelection(context: context)
    }

    /// Issues the next bounded `UID SEARCH`, or moves on once every window has
    /// been scanned or the selection cap is reached.
    private func continueSelection(context: ChannelHandlerContext) {
        if matchedUIDs.count >= selectionCap {
            isPartial = isPartial || windowIndex < windows.count
            finishSelection(context: context)
            return
        }
        guard windowIndex < windows.count else {
            finishSelection(context: context)
            return
        }
        let window = windows[windowIndex]
        let range = MessageIdentifierRange<SequenceNumber>(
            SequenceNumber(rawValue: window.lower)...SequenceNumber(rawValue: window.upper)
        )
        let key: SearchKey = .and([
            .sequenceNumbers(.range(range)),
            IMAPSearchHandler.searchKey(for: criteria),
        ])
        step = .search
        send(.uidSearch(key: key), tag: "S\(windowIndex)", context: context)
    }

    /// Selection is complete: either sample the matches (preview) or start
    /// applying the action in bounded batches.
    private func finishSelection(context: ChannelHandlerContext) {
        // Newest first, and never act on more than the user was shown.
        matchedUIDs.sort(by: >)
        if matchedUIDs.count > selectionCap {
            isPartial = true
            matchedUIDs = Array(matchedUIDs.prefix(selectionCap))
        }

        guard action != nil else { return beginSample(context: context) }
        guard !matchedUIDs.isEmpty else { return settleApplied(context: context) }
        batches = SequenceWindow.batches(matchedUIDs)
        batchIndex = 0
        step = .apply
        continueApply(context: context)
    }

    private func beginSample(context: ChannelHandlerContext) {
        let sampleUIDs = Array(matchedUIDs.prefix(max(0, sampleLimit)))
        guard let set = Self.identifierSet(for: sampleUIDs) else {
            return settlePreview(context: context)
        }
        step = .sample
        send(.uidFetch(.set(set), [.uid, .envelope], []), tag: sampleTag, context: context)
    }

    // MARK: - Applying

    private func continueApply(context: ChannelHandlerContext) {
        guard batchIndex < batches.count else {
            return settleApplied(context: context)
        }
        guard let set = Self.identifierSet(for: batches[batchIndex]) else {
            batchIndex += 1
            return continueApply(context: context)
        }
        step = .apply
        send(command(for: set), tag: "B\(batchIndex)", context: context)
    }

    private func command(for set: MessageIdentifierSetNonEmpty<UID>) -> Command {
        guard let destinationName else {
            return .uidStore(.set(set), [], .flags(.add(silent: true, list: [.seen])))
        }
        return .uidMove(.set(set), MailboxName(ByteBuffer(string: destinationName)))
    }

    // MARK: - Settling

    private func settlePreview(context: ChannelHandlerContext) {
        settle(.success(IMAPBulkOutcome(
            matchCount: matchedUIDs.count,
            sample: sample.sorted { $0.id > $1.id },
            isPartial: isPartial,
            affectedCount: 0
        )))
        finish(context: context)
    }

    private func settleApplied(context: ChannelHandlerContext) {
        settle(.success(IMAPBulkOutcome(
            matchCount: matchedUIDs.count,
            sample: [],
            isPartial: isPartial,
            affectedCount: affectedCount
        )))
        finish(context: context)
    }

    private func finish(context: ChannelHandlerContext) {
        step = .done
        send(.logout, tag: logoutTag, context: context)
        context.close(promise: nil)
    }

    private func send(_ command: Command, tag: String, context: ChannelHandlerContext) {
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(part)), promise: nil)
    }

    // MARK: - Helpers

    /// Builds a UID set for a STORE/MOVE/FETCH command. Contiguous UIDs collapse
    /// into ranges, keeping the command line short. Returns `nil` for an empty
    /// selection, which IMAP has no valid syntax for.
    static func identifierSet(for uids: [UInt32]) -> MessageIdentifierSetNonEmpty<UID>? {
        let ranges = uids.compactMap { raw -> MessageIdentifierRange<UID>? in
            guard let uid = UID(exactly: raw) else { return nil }
            return MessageIdentifierRange<UID>(uid...uid)
        }
        guard !ranges.isEmpty else { return nil }
        return MessageIdentifierSetNonEmpty(set: MessageIdentifierSet<UID>(ranges))
    }

    private func isOK(_ state: TaggedResponse.State) -> Bool {
        if case .ok = state { return true }
        return false
    }

    private func failTagged(_ state: TaggedResponse.State) {
        switch state {
        case .no(let text), .bad(let text):
            let error: MailError = step == .login
                ? .authenticationFailed(text.text)
                : .commandFailed(describe(text.text))
            settle(.failure(error))
        case .ok:
            break
        }
    }

    /// A server without the MOVE extension rejects `UID MOVE` with an opaque
    /// error; say what actually went wrong so the user isn't left guessing.
    private func describe(_ text: String) -> String {
        guard step == .apply, destinationName != nil else { return text }
        return "\(text) (the server may not support moving messages in bulk)"
    }

    private func captureUIDValidity(from payload: ResponsePayload) {
        guard case .conditionalState(.ok(let text)) = payload,
              case .some(.uidValidity(let value)) = text.code else {
            return
        }
        selectedUIDValidity = UInt32(value)
    }

    private func captureUIDValidity(from state: TaggedResponse.State) {
        guard case .ok(let text) = state,
              case .some(.uidValidity(let value)) = text.code else {
            return
        }
        selectedUIDValidity = UInt32(value)
    }

    private func settle(_ result: Result<IMAPBulkOutcome, Error>) {
        guard !settled else { return }
        settled = true
        promise.completeWith(result)
    }

    private static func address(from element: EmailAddressListElement) -> MailAddress? {
        guard case .singleAddress(let address) = element else { return nil }
        guard let mailbox = address.mailbox, let host = address.host else { return nil }
        let email = "\(String(buffer: mailbox))@\(String(buffer: host))"
        let name = address.personName.map { String(buffer: $0) }
        return MailAddress(name: name, email: email)
    }
}
