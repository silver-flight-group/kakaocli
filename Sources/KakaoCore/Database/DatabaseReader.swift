import CSQLCipher
import Foundation

/// Reads KakaoTalk's encrypted SQLite database using SQLCipher.
public final class DatabaseReader: @unchecked Sendable {
    private var db: OpaquePointer?
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    deinit {
        close()
    }

    /// Open the database. If a key is provided, attempts PRAGMA key (requires SQLCipher).
    /// Tries cipher compatibility modes 3 and 4 (for newer KakaoTalk versions).
    public func open(key: String? = nil) throws {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw KakaoError.databaseNotFound(databasePath)
        }

        if let key {
            // Try compatibility mode 3 first (legacy), then 4 (newer versions)
            let compatModes = [3, 4]
            for compat in compatModes {
                // Close previous attempt if any
                if db != nil { sqlite3_close(db); db = nil }

                let result = sqlite3_open_v2(
                    databasePath, &db,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
                )
                guard result == SQLITE_OK else {
                    let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                    throw KakaoError.databaseOpenFailed(msg)
                }

                do {
                    try exec("PRAGMA cipher_default_compatibility = \(compat)")
                    try exec("PRAGMA KEY='\(key)'")
                    try exec("SELECT count(*) FROM sqlite_master")
                    return // success
                } catch {
                    continue
                }
            }
            throw KakaoError.databaseOpenFailed(
                "PRAGMA key failed with all cipher compatibility modes — " +
                "database is encrypted and key may be wrong, or SQLCipher may not be linked. " +
                "Install via: brew install sqlcipher"
            )
        } else {
            let result = sqlite3_open_v2(
                databasePath, &db,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil
            )
            guard result == SQLITE_OK else {
                let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
                throw KakaoError.databaseOpenFailed(msg)
            }
        }
    }

    /// Try opening the database with a key. Returns true if the key is valid.
    public func tryOpen(key: String) -> Bool {
        do {
            try open(key: key)
            return true
        } catch {
            close()
            return false
        }
    }

    public func close() {
        if let db {
            sqlite3_close(db)
        }
        db = nil
    }

    // MARK: - Queries

    /// Display names for every user, resolved once. Group chats are named from
    /// their members, so without this it would be a query per row.
    private var userNamesCache: [Int64: String]?

    private func userNames() throws -> [Int64: String] {
        if let userNamesCache { return userNamesCache }
        let pairs = try query(
            "SELECT userId, COALESCE(displayName, friendNickName, nickName) FROM NTUser",
            bind: []
        ) { ($0.int64(0), $0.string(1) ?? "") }
        let map = pairs.reduce(into: [Int64: String]()) { acc, pair in
            if !pair.1.isEmpty { acc[pair.0] = pair.1 }
        }
        userNamesCache = map
        return map
    }

    /// List all chat rooms, named the way KakaoTalk names them.
    ///
    /// The previous version considered only `chatName` and the direct-chat
    /// partner, which left group chats and open chats as "(unknown)" — 9 of 60
    /// rooms on my install, all of them indistinguishable from each other. The
    /// name is actually assembled from four more places, and taking them in
    /// this order reproduces the desktop app's list exactly (verified against a
    /// live accessibility dump: every visible row matched, and the only names
    /// produced that the app doesn't show are the ones it hides behind its
    /// "Silent Chatroom" folder):
    ///
    ///   1. `NTChatRoom.chatName` — a name set on the room itself.
    ///   2. `NTChatMeta.content` where `type = 3` — the room title, which is
    ///      where a renamed group chat actually stores its name.
    ///   3. `NTOpenLink.linkName` via `linkId` — open chats are named by their
    ///      link, and nothing on the chat row carries it.
    ///   4. The other participant, for a direct chat.
    ///   5. Otherwise the member names joined with ", " — how KakaoTalk labels
    ///      an unnamed group chat. Self is excluded and the rest sorted by user
    ///      id, which is the order the app displays them in.
    ///
    /// `chatId = -1` is excluded: it is a sentinel with no members and no name,
    /// not a chat, and the app doesn't list it either.
    public func chats(limit: Int = 50) throws -> [Chat] {
        let users = try userNames()
        let me = Int64((try? DeviceInfo.userId()) ?? 0)
        let sql = """
            SELECT r.chatId, r.type, r.chatName, r.activeMembersCount,
                   r.lastLogId, r.lastUpdatedAt, r.countOfNewMessage,
                   u.displayName, u.friendNickName, u.nickName,
                   o.linkName, m.content, r.displayMemberIds
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            LEFT JOIN NTOpenLink o ON o.linkId = r.linkId
            LEFT JOIN NTChatMeta m ON m.chatId = r.chatId AND m.type = 3
            WHERE r.chatId != -1
            ORDER BY r.lastUpdatedAt DESC
            LIMIT ?
            """
        return try query(sql, bind: [.int(limit)]) { row in
            Chat(
                id: row.int64(0),
                type: Chat.ChatType.from(rawInt: row.int(1)),
                displayName: Self.chatDisplayName(
                    chatName: row.string(2),
                    metaTitle: row.string(11),
                    linkName: row.string(10),
                    directPartner: row.string(7) ?? row.string(8) ?? row.string(9),
                    memberIds: row.blob(12),
                    users: users,
                    selfUserId: me
                ),
                memberCount: row.int(3),
                lastMessageId: row.optionalInt64(4),
                lastMessageAt: row.optionalKakaoDate(5),
                unreadCount: row.int(6)
            )
        }
    }

    /// See `chats(limit:)` for why the order of these fallbacks is what it is.
    static func chatDisplayName(
        chatName: String?,
        metaTitle: String?,
        linkName: String?,
        directPartner: String?,
        memberIds: Data?,
        users: [Int64: String],
        selfUserId: Int64
    ) -> String {
        for candidate in [chatName, metaTitle, linkName, directPartner] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        if let memberIds, let ids = decodeMemberIds(memberIds) {
            let names = ids.filter { $0 != selfUserId }.sorted().compactMap { users[$0] }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return "(unknown)"
    }

    /// `displayMemberIds` is a binary plist holding an array of user ids.
    static func decodeMemberIds(_ data: Data) -> [Int64]? {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ),
              let numbers = plist as? [NSNumber]
        else { return nil }
        return numbers.map(\.int64Value)
    }

    /// Get messages for a chat, optionally filtered by time.
    public func messages(chatId: Int64? = nil, since: Date? = nil, limit: Int = 50) throws -> [Message] {
        var conditions: [String] = []
        var bindings: [SQLValue] = []

        if let chatId {
            conditions.append("m.chatId = ?")
            bindings.append(.int64(chatId))
        }
        if let since {
            // KakaoTalk stores timestamps as seconds since epoch
            conditions.append("m.sentAt >= ?")
            bindings.append(.int64(Int64(since.timeIntervalSince1970)))
        }

        let where_ = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            \(where_)
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        bindings.append(.int(limit))

        let myUserId = try self.myUserId()
        return try query(sql, bind: bindings) { row in
            Message(
                id: row.int64(0),
                chatId: row.int64(1),
                senderId: row.int64(2),
                senderName: row.string(3),
                text: row.string(4),
                type: Message.MessageType(rawValue: row.int(5)),
                createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == myUserId
            )
        }
    }

    /// Full-text search across messages.
    public func search(query: String, limit: Int = 20) throws -> [Message] {
        let sql = """
            SELECT m.logId, m.chatId, m.authorId,
                   COALESCE(u.displayName, u.friendNickName, u.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTUser u ON m.authorId = u.userId AND u.linkId = 0
            WHERE m.message LIKE ?
            ORDER BY m.sentAt DESC
            LIMIT ?
            """
        let myUserId = try self.myUserId()
        return try self.query(sql, bind: [.string("%\(query)%"), .int(limit)]) { row in
            Message(
                id: row.int64(0),
                chatId: row.int64(1),
                senderId: row.int64(2),
                senderName: row.string(3),
                text: row.string(4),
                type: Message.MessageType(rawValue: row.int(5)),
                createdAt: row.kakaoDate(6),
                isFromMe: row.int64(2) == myUserId
            )
        }
    }

    /// Get the logged-in user's ID from NTChatContext.
    public func myUserId() throws -> Int64 {
        let results = try query("SELECT userId FROM NTChatContext LIMIT 1", bind: []) { row in
            row.int64(0)
        }
        return results.first ?? 0
    }

    /// Get the maximum logId in the messages table (used by DatabaseWatcher).
    public func maxLogId() throws -> Int64 {
        let results = try query("SELECT MAX(logId) FROM NTChatMessage", bind: []) { row in
            row.optionalInt64(0)
        }
        return results.first.flatMap { $0 } ?? 0
    }

    /// Get messages with logId strictly greater than the given value.
    /// Returns SyncMessage structs suitable for JSON streaming.
    public func messagesSince(logId: Int64, myUserId: Int64) throws -> [SyncMessage] {
        let sql = """
            SELECT m.logId, m.chatId,
                   COALESCE(r.chatName, u.displayName, u.friendNickName, u.nickName) as chatName,
                   m.authorId,
                   COALESCE(u2.displayName, u2.friendNickName, u2.nickName) as senderName,
                   m.message, m.type, m.sentAt
            FROM NTChatMessage m
            LEFT JOIN NTChatRoom r ON m.chatId = r.chatId
            LEFT JOIN NTUser u ON r.directChatMemberUserId = u.userId AND u.linkId = 0
            LEFT JOIN NTUser u2 ON m.authorId = u2.userId AND u2.linkId = 0
            WHERE m.logId > ?
            ORDER BY m.logId ASC
            LIMIT 100
            """
        let formatter = ISO8601DateFormatter()
        return try query(sql, bind: [.int64(logId)]) { row in
            SyncMessage(
                type: "message",
                logId: row.int64(0),
                chatId: row.int64(1),
                chatName: row.string(2),
                senderId: row.int64(3),
                senderName: row.string(4),
                text: row.string(5),
                messageType: row.int(6),
                timestamp: formatter.string(from: row.kakaoDate(7)),
                isFromMe: row.int64(3) == myUserId
            )
        }
    }

    /// Run an arbitrary read-only SQL query and return results as arrays of Any.
    public func rawQuery(_ sql: String) throws -> [[Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        let colCount = sqlite3_column_count(stmt)
        var results: [[Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any] = []
            for i in 0..<colCount {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:
                    row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_NULL:
                    row.append("")
                default:
                    row.append("")
                }
            }
            results.append(row)
        }
        return results
    }

    /// Discover the actual database schema.
    public func schema() throws -> [(name: String, sql: String)] {
        try query(
            "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name",
            bind: []
        ) { row in
            (name: row.string(0) ?? "", sql: row.string(1) ?? "")
        }
    }

    // MARK: - SQLite Helpers

    enum SQLValue {
        case int(Int)
        case int64(Int64)
        case double(Double)
        case string(String)
        case null
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if result != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw KakaoError.sqlError(msg)
        }
    }

    private func query<T>(_ sql: String, bind: [SQLValue], transform: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw KakaoError.sqlError("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in bind.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .int(let v): sqlite3_bind_int(stmt, idx, Int32(v))
            case .int64(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .string(let v): sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }

        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(transform(Row(stmt: stmt!)))
        }
        return results
    }

    struct Row {
        let stmt: OpaquePointer

        func int(_ col: Int32) -> Int {
            Int(sqlite3_column_int(stmt, col))
        }

        func int64(_ col: Int32) -> Int64 {
            sqlite3_column_int64(stmt, col)
        }

        func optionalInt64(_ col: Int32) -> Int64? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : int64(col)
        }

        func string(_ col: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        func bool(_ col: Int32) -> Bool {
            sqlite3_column_int(stmt, col) != 0
        }

        func blob(_ col: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(stmt, col) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, col))
            guard count > 0 else { return nil }
            return Data(bytes: bytes, count: count)
        }

        /// KakaoTalk stores timestamps as seconds since epoch.
        func kakaoDate(_ col: Int32) -> Date {
            let ts = sqlite3_column_int64(stmt, col)
            return Date(timeIntervalSince1970: Double(ts))
        }

        func optionalKakaoDate(_ col: Int32) -> Date? {
            let val = sqlite3_column_int64(stmt, col)
            return val == 0 ? nil : Date(timeIntervalSince1970: Double(val))
        }
    }
}

extension Chat.ChatType {
    /// Map KakaoTalk's integer chat type to our enum.
    static func from(rawInt: Int) -> Self {
        // KakaoTalk uses integer types; exact mapping TBD via testing
        switch rawInt {
        case 0: return .direct
        case 1: return .group
        default: return .unknown
        }
    }
}
