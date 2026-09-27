import Foundation

/// Position in a chat's history: messages are ordered by (sentAt, logId).
/// Serialized as "<sentAt>.<logId>".
public struct MessageCursor: Sendable, Equatable {
    public let sentAt: Int64
    public let logId: Int64

    public init(sentAt: Int64, logId: Int64) {
        self.sentAt = sentAt
        self.logId = logId
    }

    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let s = Int64(parts[0]), let l = Int64(parts[1]) else { return nil }
        self.init(sentAt: s, logId: l)
    }

    public var string: String { "\(sentAt).\(logId)" }
}

/// Filters for `DatabaseReader.messageHistory`.
public struct HistoryQuery: Sendable {
    public var chatId: Int64?
    public var excludeChatIds: [Int64] = []
    public var logId: Int64?
    public var since: Int64?
    public var until: Int64?
    public var before: MessageCursor?
    public var after: MessageCursor?
    public var contains: String?
    public var limit: Int = 100

    public init() {}
}

/// A message with the raw fields needed for pagination and attachments.
public struct HistoryMessage: Sendable {
    public let logId: Int64
    public let chatId: Int64
    public let senderId: Int64
    public let senderName: String?
    public let text: String?
    /// Raw KakaoTalk message type code (e.g. 1 text, 2 photo, 18 file, 27 multi-photo).
    public let typeCode: Int
    /// Seconds since epoch.
    public let sentAt: Int64
    /// Raw attachment JSON as stored by KakaoTalk, if any.
    public let attachment: String?
    public let localFilePath: String?
    public let isFromMe: Bool

    public var cursor: MessageCursor { MessageCursor(sentAt: sentAt, logId: logId) }
}
