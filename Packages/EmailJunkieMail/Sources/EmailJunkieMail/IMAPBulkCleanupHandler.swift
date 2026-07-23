import Foundation
import NIOCore
import NIOIMAP

/// Drives the bulk-cleanup conversation:
///
/// `LOGIN → SELECT → SEARCH sequence windows → FETCH UIDs → [sample FETCH |
/// UID STORE/MOVE in batches] → LOGOUT`
///
/// Selection is deliberately completed before any mutation: a `UID MOVE`
/// removes messages and renumbers the sequence space, which would corrupt a
/// scan still walking that space.
final class IMAPBulkCleanupHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    enum Step {
        case greeting, login, select, search, resolve, sample, apply, done
    }

    /// Accumulates one FETCH response; `IMAPBulkCleanupHandler+Envelope` fills it.
    struct PartialMessage {
        var sequenceNumber: UInt32?
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
    let destinationName: String?
    private let request: IMAPBulkCleanupRequest
    let promise: EventLoopPromise<IMAPBulkOutcome>

    private var criteria: MailSearchCriteria { request.criteria }
    private var action: MailBulkAction? { request.action }
    private var sampleLimit: Int { request.sampleLimit }
    private var selectionCap: Int { request.selectionCap }
    private var onProgress: (@Sendable (MailBulkProgress) -> Void)? { request.onProgress }

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let sampleTag = "A3"
    private let logoutTag = "A4"

    var step: Step = .greeting
    var settled = false
    private var messageCount = 0
    var selectedUIDValidity: UInt32?

    private var windows: [(lower: UInt32, upper: UInt32)] = []
    private var windowIndex = 0
    private var pendingSequenceNumbers: [UInt32] = []
    private var matchedUIDs: [UInt32] = []
    private var isPartial = false

    private var batches: [[UInt32]] = []
    private var batchIndex = 0
    private var affectedCount = 0

    var sample: [MailMessage] = []
    var current: PartialMessage?

    init(
        email: String,
        password: String,
        mailboxName: String,
        destinationName: String?,
        request: IMAPBulkCleanupRequest,
        promise: EventLoopPromise<IMAPBulkOutcome>
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.destinationName = destinationName
        self.request = request
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
                pendingSequenceNumbers.append(contentsOf: ids.map(\.rawValue))
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
            if let selection = request.selection, action != nil {
                beginProvidedSelection(selection, context: context)
            } else {
                beginSelection(context: context)
            }
        case sampleTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            settlePreview(context: context)
        default:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            if step == .search {
                resolveCurrentWindow(context: context)
            } else if step == .resolve {
                pendingSequenceNumbers.removeAll()
                windowIndex += 1
                continueSelection(context: context)
            } else if step == .apply {
                // Guard the index rather than trusting tag ordering: an
                // unsolicited or duplicated tagged response would otherwise
                // index past the last batch and crash the app.
                guard batchIndex < batches.count else { return }
                affectedCount += batches[batchIndex].count
                onProgress?(MailBulkProgress(processed: affectedCount, total: matchedUIDs.count))
                batchIndex += 1
                continueApply(context: context)
            }
        }
    }

    // MARK: - Selection

    private func beginSelection(context: ChannelHandlerContext) {
        windows = SequenceWindow.windows(total: messageCount)
        windowIndex = 0
        step = .search
        continueSelection(context: context)
    }

    /// Applies the exact UID set approved by a preview instead of rerunning the
    /// live filter, so newly arrived matching mail is not swept into the run.
    private func beginProvidedSelection(
        _ selection: MailBulkSelection,
        context: ChannelHandlerContext
    ) {
        if let expectedUIDValidity = selection.uidValidity {
            guard let selectedUIDValidity, expectedUIDValidity == selectedUIDValidity else {
                settle(.failure(MailError.commandFailed(
                    "The mailbox changed since the preview. Preview again before running cleanup."
                )))
                return finish(context: context)
            }
        }
        matchedUIDs = selection.uids
        finishSelection(context: context)
    }

    /// Issues the next bounded `SEARCH`, or moves on once every window has been
    /// scanned or the selection cap is reached.
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
            IMAPSearchHandler.searchKey(for: criteria)
        ])
        pendingSequenceNumbers.removeAll()
        step = .search
        send(.search(key: key), tag: "S\(windowIndex)", context: context)
    }

    private func resolveCurrentWindow(context: ChannelHandlerContext) {
        guard let set = Self.sequenceIdentifierSet(for: pendingSequenceNumbers) else {
            windowIndex += 1
            continueSelection(context: context)
            return
        }
        step = .resolve
        send(.fetch(.set(set), [.uid], []), tag: "F\(windowIndex)", context: context)
    }

    func recordResolvedUID(_ uid: UInt32, for sequenceNumber: UInt32?) {
        guard let sequenceNumber, pendingSequenceNumbers.contains(sequenceNumber) else { return }
        matchedUIDs.append(uid)
    }

    /// Selection is complete: either sample the matches (preview) or start
    /// applying the action in bounded batches.
    private func finishSelection(context: ChannelHandlerContext) {
        // Newest first, and never act on more than the user was shown.
        matchedUIDs = Array(Set(matchedUIDs)).sorted(by: >)
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
        guard let command = command(for: set) else {
            settle(.failure(MailError.commandFailed(
                "No destination folder is configured for this cleanup action."
            )))
            return finish(context: context)
        }
        step = .apply
        send(command, tag: "B\(batchIndex)", context: context)
    }

    /// Keys off the action rather than the presence of a destination: a move
    /// action that somehow arrived without a destination folder must fail
    /// loudly, not silently degrade into marking the batch read.
    private func command(for set: MessageIdentifierSetNonEmpty<UID>) -> Command? {
        switch action {
        case .markRead:
            return .uidStore(.set(set), [], .flags(.add(silent: true, list: [.seen])))
        case .archive, .moveToTrash:
            guard let destinationName else { return nil }
            return .uidMove(.set(set), MailboxName(ByteBuffer(string: destinationName)))
        case nil:
            return nil
        }
    }

    // MARK: - Settling

    private func settlePreview(context: ChannelHandlerContext) {
        settle(.success(IMAPBulkOutcome(
            matchCount: matchedUIDs.count,
            sample: sample.sorted { $0.id > $1.id },
            isPartial: isPartial,
            selection: MailBulkSelection(uidValidity: selectedUIDValidity, uids: matchedUIDs),
            affectedCount: 0
        )))
        finish(context: context)
    }

    private func settleApplied(context: ChannelHandlerContext) {
        settle(.success(IMAPBulkOutcome(
            matchCount: matchedUIDs.count,
            sample: [],
            isPartial: isPartial,
            selection: nil,
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
}
