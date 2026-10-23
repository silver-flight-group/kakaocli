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
    /// Kept open across polls — opening runs SQLCipher's key derivation, which is too costly per poll.
    private var reader: DatabaseReader?
    private var myUserId: Int64 = 0

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
                if !messages.isEmpty {
                    if let maxId = messages.map(\.logId).max() {
                        lastLogId = maxId
                    }
                    onMessages(messages)
                }
            } catch {
                // Drop the connection so the next poll reopens it (e.g. the DB file was replaced).
                closeReader()
                onError(error)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        closeReader()
    }

    public func stop() {
        running = false
    }

    // MARK: - Private

    private func openReader() throws -> DatabaseReader {
        if let reader { return reader }
        let newReader = DatabaseReader(databasePath: databasePath)
        try newReader.open(key: key)
        myUserId = try newReader.myUserId()
        reader = newReader
        return newReader
    }

    private func closeReader() {
        reader?.close()
        reader = nil
    }

    private func fetchMaxLogId() throws -> Int64 {
        try openReader().maxLogId()
    }

    private func fetchNewMessages() throws -> [SyncMessage] {
        try openReader().messagesSince(logId: lastLogId, myUserId: myUserId)
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
