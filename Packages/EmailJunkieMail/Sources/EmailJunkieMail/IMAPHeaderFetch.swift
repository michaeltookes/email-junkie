import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

extension IMAPMailProvider {
    /// Fetches a bounded set of header fields for one message via
    /// `BODYSTRUCTURE` plus `BODY.PEEK[HEADER.FIELDS (...)]`. Peek avoids setting
    /// `\Seen`. Used by the watcher's reply-worthiness gate (item 17) to see
    /// list/automation/MIME content-type signals that the ENVELOPE fetch does not
    /// carry.
    public func fetchHeaderFields(
        _ credentials: MailAccountCredentials,
        mailbox: Mailbox,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil
    ) async throws -> MailHeaderFields {
        guard credentials.isComplete else { throw MailError.incompleteCredentials }
        guard uid > 0 else { throw MailError.commandFailed("A message UID is required to fetch headers.") }

        let attempts = IMAPHeaderFetchAttempts()
        let sslContext = try NIOSSLContext(configuration: TLSConfiguration.makeClientConfiguration())
        let host = credentials.host
        let email = credentials.email
        let password = credentials.appPassword
        let mailboxName = mailbox.imapName(using: credentials.mailboxNaming)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                do {
                    let ssl = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    let promise = attempts.makePromise(for: channel)
                    let handler = IMAPHeaderFetchHandler(
                        email: email,
                        password: password,
                        mailboxName: mailboxName,
                        uid: uid,
                        expectedUIDValidity: expectedUIDValidity,
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
        guard let headerFuture = attempts.future(for: channel) else {
            try? await channel.close().get()
            throw MailError.connectionFailed("The mail connection could not start fetching.")
        }

        let timeoutTask = channel.eventLoop.scheduleTask(in: timeout) {
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            let headers = try await headerFuture.get()
            try? await channel.close().get()
            return headers
        } catch {
            try? await channel.close().get()
            throw error
        }
    }
}

/// Tracks header-fetch futures per channel (mirrors the body-fetch tracker) so
/// Happy Eyeballs attempts can't settle the winning channel's result.
final class IMAPHeaderFetchAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var futures: [ObjectIdentifier: EventLoopFuture<MailHeaderFields>] = [:]

    func makePromise(for channel: Channel) -> EventLoopPromise<MailHeaderFields> {
        let promise = channel.eventLoop.makePromise(of: MailHeaderFields.self)
        lock.lock()
        futures[ObjectIdentifier(channel)] = promise.futureResult
        lock.unlock()
        return promise
    }

    func future(for channel: Channel) -> EventLoopFuture<MailHeaderFields>? {
        lock.lock()
        defer { lock.unlock() }
        return futures.removeValue(forKey: ObjectIdentifier(channel))
    }
}

/// Drives LOGIN → SELECT → UID FETCH (BODYSTRUCTURE + BODY.PEEK[HEADER.FIELDS (...)])
/// → LOGOUT and completes `promise` with the parsed header fields plus MIME part
/// content types. A FETCH that returns no header section (the message carries none
/// of the requested fields) settles with empty fields, not an error; absence of
/// these headers is a valid, reply-worthy signal.
final class IMAPHeaderFetchHandler: ChannelInboundHandler {
    typealias InboundIn = Response

    private enum Step {
        case greeting, login, select, fetch, done
    }

    private let email: String
    private let password: String
    private let mailboxName: String
    private let uid: UInt32
    private let expectedUIDValidity: UInt32?
    private let promise: EventLoopPromise<MailHeaderFields>

    private let loginTag = "A1"
    private let selectTag = "A2"
    private let fetchTag = "A3"
    private let logoutTag = "A4"

    private var step: Step = .greeting
    private var settled = false
    private var headerBytes = ByteBuffer()
    private var receivingHeader = false
    private var bodyContentTypes: [String] = []
    private var selectedUIDValidity: UInt32?

    init(
        email: String,
        password: String,
        mailboxName: String,
        uid: UInt32,
        expectedUIDValidity: UInt32? = nil,
        promise: EventLoopPromise<MailHeaderFields>
    ) {
        self.email = email
        self.password = password
        self.mailboxName = mailboxName
        self.uid = uid
        self.expectedUIDValidity = expectedUIDValidity
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
        settle(.failure(MailError.connectionFailed(String(describing: error))))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(MailError.connectionFailed("The connection closed before the fetch completed.")))
        context.fireChannelInactive()
    }

    // MARK: - Response handling

    private func handleUntagged(_ payload: ResponsePayload, context: ChannelHandlerContext) {
        captureUIDValidity(from: payload)

        // Only the greeting matters here; SELECT's untagged data (EXISTS etc.)
        // is irrelevant because we address the message by UID.
        if step == .greeting {
            send(.login(username: email, password: password), tag: loginTag, context: context)
            step = .login
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
            guard verifySelectedUIDValidity() else {
                step = .done
                send(.logout, tag: logoutTag, context: context)
                context.close(promise: nil)
                return
            }
            let range = MessageIdentifierRange<UID>(UID(rawValue: uid))
            let set = MessageIdentifierSetNonEmpty(range: range)
            let section = SectionSpecifier.headerFields(MailHeaderFields.requestedFieldNames)
            send(
                .uidFetch(
                    .set(set),
                    [.bodyStructure(extensions: true), .bodySection(peek: true, section, nil)],
                    []
                ),
                tag: fetchTag,
                context: context
            )
            step = .fetch
        case fetchTag:
            guard isOK(tagged.state) else { return failTagged(tagged.state) }
            var fields = MailHeaderFields.parse(headerData())
            fields.bodyContentTypes = bodyContentTypes
            settle(.success(fields))
            step = .done
            send(.logout, tag: logoutTag, context: context)
            context.close(promise: nil)
        default:
            break
        }
    }

    private func handleFetch(_ response: FetchResponse) {
        switch response {
        case .simpleAttribute(.body(let body, hasExtensionData: _)):
            bodyContentTypes = Self.bodyContentTypes(from: body)
        case .streamingBegin(let kind, _):
            // Only accumulate the BODY[HEADER.FIELDS] stream — ignore any other section.
            if case .body = kind {
                receivingHeader = true
            }
        case .streamingBytes(var chunk):
            if receivingHeader { headerBytes.writeBuffer(&chunk) }
        case .streamingEnd:
            receivingHeader = false
        default:
            break
        }
    }

    // MARK: - Commands

    private func send(_ command: Command, tag: String, context: ChannelHandlerContext) {
        let part = CommandStreamPart.tagged(TaggedCommand(tag: tag, command: command))
        context.writeAndFlush(NIOAny(IMAPClientHandler.Message.part(part)), promise: nil)
    }

    // MARK: - Helpers

    private func isOK(_ state: TaggedResponse.State) -> Bool {
        if case .ok = state { return true }
        return false
    }

    private func failTagged(_ state: TaggedResponse.State) {
        switch state {
        case .no(let text), .bad(let text):
            let error: MailError = step == .login
                ? .authenticationFailed(text.text)
                : .commandFailed(text.text)
            settle(.failure(error))
        case .ok:
            break
        }
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

    private func verifySelectedUIDValidity() -> Bool {
        guard let expectedUIDValidity else { return true }
        guard let selectedUIDValidity else {
            settle(.failure(MailError.commandFailed("The mailbox UIDVALIDITY could not be verified.")))
            return false
        }
        guard selectedUIDValidity == expectedUIDValidity else {
            settle(.failure(MailError.commandFailed("The mailbox changed before the message headers were fetched.")))
            return false
        }
        return true
    }

    private func headerData() -> Data {
        var buffer = headerBytes
        return Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }

    private static func bodyContentTypes(from body: MessageAttribute.BodyStructure) -> [String] {
        guard case .valid(let structure) = body else { return [] }

        var contentTypes: [String] = []
        structure.enumerateParts { _, part in
            guard !Self.isAttachment(part) else { return }
            let contentType = Self.contentTypeString(for: part)
            guard !contentTypes.contains(contentType) else { return }
            contentTypes.append(contentType)
        }
        return contentTypes
    }

    private static func contentTypeString(for part: BodyStructure) -> String {
        let contentType = mediaTypeString(for: part.mediaType)
        guard Self.isCalendarMediaType(contentType),
              let method = Self.parameter(named: "method", in: part) else {
            return contentType
        }
        return "\(contentType); method=\(method)"
    }

    private static func mediaTypeString(for mediaType: Media.MediaType) -> String {
        "\(String(mediaType.topLevel))/\(String(mediaType.sub))"
    }

    private static func isCalendarMediaType(_ contentType: String) -> Bool {
        contentType == "text/calendar" || contentType == "application/ics"
    }

    private static func isAttachment(_ part: BodyStructure) -> Bool {
        disposition(for: part)?.kind == .attachment
    }

    private static func disposition(for part: BodyStructure) -> BodyStructure.Disposition? {
        switch part {
        case .singlepart(let singlepart):
            return singlepart.extension?.dispositionAndLanguage?.disposition
        case .multipart(let multipart):
            return multipart.extension?.dispositionAndLanguage?.disposition
        }
    }

    private static func parameter(named name: String, in part: BodyStructure) -> String? {
        let parameters: [(String, String)]
        switch part {
        case .singlepart(let singlepart):
            parameters = singlepart.fields.parameters.map { ($0.key, $0.value) }
        case .multipart(let multipart):
            parameters = multipart.extension?.parameters.map { ($0.key, $0.value) } ?? []
        }
        return parameters.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    private func settle(_ result: Result<MailHeaderFields, Error>) {
        guard !settled else { return }
        settled = true
        promise.completeWith(result)
    }
}
