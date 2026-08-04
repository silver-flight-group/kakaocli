import Foundation

/// A KakaoTalk chat room.
public struct Chat: Sendable {
    public let id: Int64
    public let type: ChatType
    public let displayName: String
    public let memberCount: Int
    public let lastMessageId: Int64?
    public let lastMessageAt: Date?
    public let unreadCount: Int
    public let isSelfChat: Bool

    public enum ChatType: String, Sendable {
        case direct = "direct"
        case group = "group"
        case openChat = "open"
        case selfChat = "self"
        case unknown = "unknown"
    }
}
