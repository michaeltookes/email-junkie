import Foundation

/// A bulk triage action applied to every message matching a filter (item 42).
///
/// Ordered least- to most-destructive. Nothing here permanently deletes mail:
/// `moveToTrash` relocates messages to the account's Trash folder, where the
/// provider's own retention rules apply and the user can still recover them.
/// Permanent `UID EXPUNGE` is deliberately out of scope for this slice.
public enum MailBulkAction: Sendable, Equatable, Hashable, CaseIterable {
    /// Set `\Seen` on every match (IMAP `UID STORE +FLAGS (\Seen)`).
    case markRead
    /// Move every match to the account's Archive folder (IMAP `UID MOVE`).
    case archive
    /// Move every match to the account's Trash folder (IMAP `UID MOVE`).
    case moveToTrash

    /// Whether the action relocates messages out of the source mailbox. Used to
    /// decide whether a confirmation step is required and how it is worded.
    public var isDestructive: Bool {
        switch self {
        case .markRead: return false
        case .archive, .moveToTrash: return true
        }
    }

    /// The mailbox a move-style action targets, or `nil` for in-place actions.
    public var destination: Mailbox? {
        switch self {
        case .markRead: return nil
        case .archive: return .archive
        case .moveToTrash: return .trash
        }
    }

    /// Short imperative label for buttons and confirmation copy.
    public var verb: String {
        switch self {
        case .markRead: return "Mark read"
        case .archive: return "Archive"
        case .moveToTrash: return "Move to Trash"
        }
    }
}

/// Pure windowing math for bounded bulk selection.
///
/// A bulk filter can match tens of thousands of messages, but a single
/// IMAP `SEARCH` returns every matching sequence number on one response line,
/// and `UID SEARCH` has the same shape for UIDs. Either can overflow
/// NIO-IMAP's 8 KB frame cap and fail the whole operation (item 45).
///
/// So selection walks the mailbox in bounded slices instead: each slice searches
/// only a fixed span of sequence numbers, so the server's reply is bounded by
/// construction no matter how large the mailbox is.
enum SequenceWindow {
    /// Max sequence numbers searched per window. A window can return at most one
    /// identifier per message, and identifiers on a large mailbox run ~7-8
    /// digits plus a separator, so 500 keeps the worst-case `* SEARCH` line near
    /// 4 KB — a wide margin under the 8 KB frame cap.
    static let defaultSize = 500

    /// Splits a mailbox of `total` messages into `[lower, upper]` sequence
    /// windows, newest first (highest sequence numbers first) so the most recent
    /// mail is processed before older mail. Returns an empty array when there is
    /// nothing to walk.
    static func windows(total: Int, size: Int = defaultSize) -> [(lower: UInt32, upper: UInt32)] {
        guard total > 0, size > 0 else { return [] }
        var result: [(lower: UInt32, upper: UInt32)] = []
        var upper = total
        while upper >= 1 {
            let lower = max(1, upper - size + 1)
            result.append((UInt32(lower), UInt32(upper)))
            if lower == 1 { break }
            upper = lower - 1
        }
        return result
    }

    /// Splits `uids` into batches of at most `size` for a bounded `UID STORE` /
    /// `UID MOVE`. The command line carries the UID set, so batching keeps the
    /// *outbound* command bounded just as windowing bounds the inbound reply.
    static func batches(_ uids: [UInt32], size: Int = defaultSize) -> [[UInt32]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: uids.count, by: size).map {
            Array(uids[$0..<min($0 + size, uids.count)])
        }
    }
}

/// What a bulk action *would* do, shown to the user before anything is changed.
///
/// Selection is bounded, so a preview may stop early on a very large match set;
/// `isPartial` records that so the UI can say "at least N" rather than implying
/// an exact total.
public struct MailBulkPreview: Sendable, Equatable {
    /// How many messages matched the filter.
    public var matchCount: Int
    /// A sample of the matches (newest first) so the user can eyeball what the
    /// filter actually caught before approving.
    public var sample: [MailMessage]
    /// True when scanning stopped at the selection cap, so `matchCount` is a
    /// lower bound rather than the exact total.
    public var isPartial: Bool

    public init(matchCount: Int, sample: [MailMessage], isPartial: Bool) {
        self.matchCount = matchCount
        self.sample = sample
        self.isPartial = isPartial
    }

    /// Nothing matched the filter.
    public static let empty = MailBulkPreview(matchCount: 0, sample: [], isPartial: false)
}

/// The result of applying a bulk action.
public struct MailBulkResult: Sendable, Equatable {
    /// The action that ran.
    public var action: MailBulkAction
    /// How many messages the action was applied to.
    public var affectedCount: Int

    public init(action: MailBulkAction, affectedCount: Int) {
        self.action = action
        self.affectedCount = affectedCount
    }
}

/// Progress for a long-running bulk action, reported per completed batch.
public struct MailBulkProgress: Sendable, Equatable {
    /// Messages processed so far.
    public var processed: Int
    /// Total messages the action will process.
    public var total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }

    /// Completion in `0...1`, or `0` when the total is unknown/zero.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }
}
