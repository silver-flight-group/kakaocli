import ArgumentParser
import Foundation
import KakaoCore

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Paginated message history as JSON (cursor-based, includes attachments)",
        discussion: """
            Results are newest-first, or oldest-first when --after is given.
            Pass a message's "cursor" to --before (older page) or --after (newer page).

            Examples:
              kakaocli history --chat-id 123 --limit 100
              kakaocli history --chat-id 123 --before 1790400000.4567
              kakaocli history --contains 점심 --exclude-chat-id 999
            """
    )

    @Option(name: .long, help: "Only this chat")
    var chatId: Int64?

    @Option(name: .long, help: "Exclude this chat (repeatable)")
    var excludeChatId: [Int64] = []

    @Option(name: .long, help: "Only the message with this logId")
    var logId: Int64?

    @Option(name: .long, help: "Only messages sent at or after this Unix time (seconds)")
    var since: Int64?

    @Option(name: .long, help: "Only messages sent at or before this Unix time (seconds)")
    var until: Int64?

    @Option(name: .long, help: "Only messages older than this cursor (<sentAt>.<logId>)")
    var before: String?

    @Option(name: .long, help: "Only messages newer than this cursor (<sentAt>.<logId>)")
    var after: String?

    @Option(name: .long, help: "Only messages whose text contains this string")
    var contains: String?

    @Option(name: .long, help: "Maximum number of messages (1-5000)")
    var limit: Int = 100

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    func validate() throws {
        guard (1...5000).contains(limit) else {
            throw ValidationError("--limit must be between 1 and 5000")
        }
        if before != nil && after != nil {
            throw ValidationError("--before and --after cannot be used together")
        }
        if let before, MessageCursor(string: before) == nil {
            throw ValidationError("--before must look like <sentAt>.<logId>")
        }
        if let after, MessageCursor(string: after) == nil {
            throw ValidationError("--after must look like <sentAt>.<logId>")
        }
    }

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        var q = HistoryQuery()
        q.chatId = chatId
        q.excludeChatIds = excludeChatId
        q.logId = logId
        q.since = since
        q.until = until
        q.before = before.flatMap { MessageCursor(string: $0) }
        q.after = after.flatMap { MessageCursor(string: $0) }
        q.contains = contains
        q.limit = limit

        let items = try reader.messageHistory(q).map { m -> [String: Any] in
            var dict: [String: Any] = [
                "log_id": m.logId,
                "chat_id": m.chatId,
                "sender_id": m.senderId,
                "type_code": m.typeCode,
                "sent_at": m.sentAt,
                "cursor": m.cursor.string,
                "is_from_me": m.isFromMe,
            ]
            if let v = m.senderName { dict["sender"] = v }
            if let v = m.text { dict["text"] = v }
            if let v = m.attachment, !v.isEmpty { dict["attachment"] = v }
            if let v = m.localFilePath, !v.isEmpty { dict["local_file_path"] = v }
            return dict
        }
        JSONOutput.printArray(items)
    }
}
