import CSQLCipher
import Foundation

/// Watches the KakaoTalk database for new messages by polling.
///
/// Uses `lastLogId` to track the high-water mark — only messages with
/// `logId > lastLogId` are emitted. Polling interval is configurable.
public final class DatabaseWatcher: @unchecked Sendable {
    private let databasePath: String
    private let key: String?
    private let pollInterval: TimeInterval
    private var lastLogId: Int64
    private var running = false

    public init(databasePath: String, key: String?, pollInterval: TimeInterval = 2.0, startFromLogId: Int64? = nil) {
        self.databasePath = databasePath
        self.key = key
        self.pollInterval = pollInterval
        self.lastLogId = startFromLogId ?? 0
    }

    /// Start watching. Calls `onMessages` with each batch of new messages.
    /// Calls `onError` if a poll fails. Blocks the calling thread until `stop()` is called.
    public func watch(onMessages: @escaping ([SyncMessage]) -> Void, onError: @escaping (Error) -> Void) {
        running = true

        // If no starting logId, seed from the current max
        if lastLogId == 0 {
            do {
                lastLogId = try fetchMaxLogId()
            } catch {
                onError(error)
                return
            }
        }

        while running {
            do {
                let messages = try fetchNewMessages()
                // KakaoTalk Mac은 송신 직후·서버 ack 전 상태의 메시지를 NTChatMessage에
                // logId = Int64.max 임시 placeholder로 저장한다. 그 행을 cursor에 반영하면
                // 이후 messagesSince(logId > Int64.max)가 영원히 빈 결과를 돌려줘 sync가
                // silent wedge 상태에 빠진다. 다음 polling에서 실제 logId로 갱신된 같은
                // 메시지를 다시 emit하므로 누락 위험도 없음.
                let valid = messages.filter { $0.logId != Int64.max }
                if !valid.isEmpty {
                    if let maxId = valid.map(\.logId).max() {
                        lastLogId = maxId
                    }
                    onMessages(valid)
                }
            } catch {
                onError(error)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    public func stop() {
        running = false
    }

    // MARK: - Private

    private func fetchMaxLogId() throws -> Int64 {
        let reader = DatabaseReader(databasePath: databasePath)
        try reader.open(key: key)
        defer { reader.close() }
        return try reader.maxLogId()
    }

    private func fetchNewMessages() throws -> [SyncMessage] {
        let reader = DatabaseReader(databasePath: databasePath)
        try reader.open(key: key)
        defer { reader.close() }
        let myUserId = try reader.myUserId()
        return try reader.messagesSince(logId: lastLogId, myUserId: myUserId)
    }
}

/// A message event emitted by the watcher, designed for JSON serialization.
public struct SyncMessage: Sendable, Encodable {
    public let type: String
    public let logId: Int64
    public let chatId: Int64
    public let chatName: String?
    public let senderId: Int64
    public let senderName: String?
    public let text: String?
    public let messageType: Int
    public let timestamp: String
    public let isFromMe: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case logId = "log_id"
        case chatId = "chat_id"
        case chatName = "chat_name"
        case senderId = "sender_id"
        case senderName = "sender"
        case text
        case messageType = "message_type"
        case timestamp
        case isFromMe = "is_from_me"
    }
}
