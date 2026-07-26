import Foundation
import NIOCore
import NIOIMAP

/// The apply half of `IMAPBulkCleanupHandler`: once selection has produced the
/// approved UID set, walk it in bounded batches, revalidating each batch's UIDs
/// immediately before the STORE/MOVE. Split out so the handler's selection state
/// machine stays readable on its own.
extension IMAPBulkCleanupHandler {

    // MARK: - Applying

    func continueApply(context: ChannelHandlerContext) {
        guard batchIndex < batches.count else {
            return settleApplied(context: context)
        }
        guard let set = Self.identifierSet(for: batches[batchIndex]) else {
            batchIndex += 1
            return continueApply(context: context)
        }
        currentBatchUIDs.removeAll()
        step = .validate
        send(.uidSearch(key: .uid(.set(set))), tag: "V\(batchIndex)", context: context)
    }

    /// Re-checks each concrete UID batch immediately before mutating it. A
    /// previewed UID may have been moved or expunged by another client after the
    /// preview, and IMAP can otherwise accept a command that silently ignores it.
    func mutateCurrentBatch(context: ChannelHandlerContext) {
        guard batchIndex < batches.count else {
            return settleApplied(context: context)
        }

        currentBatchUIDs = Array(Set(currentBatchUIDs)).sorted(by: >)
        let missingCount = max(0, batches[batchIndex].count - currentBatchUIDs.count)
        if missingCount > 0 {
            applyTotal = max(0, applyTotal - missingCount)
        }

        guard let set = Self.identifierSet(for: currentBatchUIDs) else {
            onProgress?(MailBulkProgress(processed: affectedCount, total: applyTotal))
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
    func command(for set: MessageIdentifierSetNonEmpty<UID>) -> Command? {
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
}
