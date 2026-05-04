import ArgumentParser
import Foundation
import KakaoCore

struct MessagesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Show recent messages"
    )

    @Option(name: .long, help: "Filter by chat name (substring match)")
    var chat: String?

    @Option(name: .long, help: "Filter by chat ID")
    var chatId: Int64?

    @Option(name: .long, help: "Show messages since (e.g. 1h, 24h, 7d)")
    var since: String?

    @Option(name: .long, help: "Maximum number of messages")
    var limit: Int = 50

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key, userId: userId)
        defer { reader.close() }

        // Resolve chat name to ID if needed
        var resolvedChatId = chatId
        if let chatName = chat, resolvedChatId == nil {
            let chats = try reader.chats(limit: 200)
            if let found = chats.first(where: { $0.displayName.localizedCaseInsensitiveContains(chatName) }) {
                resolvedChatId = found.id
            } else {
                print("Chat '\(chatName)' not found.")
                print("Available chats:")
                for c in chats.prefix(10) {
                    print("  \(c.displayName)")
                }
                throw ExitCode.failure
            }
        }

        let sinceDate = since.flatMap { parseDuration($0) }
        let messages = try reader.messages(chatId: resolvedChatId, since: sinceDate, limit: limit)

        if json {
            let items = messages.map { msg -> [String: Any] in
                var dict: [String: Any] = [
                    "id": msg.id,
                    "chat_id": msg.chatId,
                    "sender_id": msg.senderId,
                    "type": String(describing: msg.type),
                    "timestamp": ISO8601DateFormatter().string(from: msg.createdAt),
                    "is_from_me": msg.isFromMe,
                ]
                if let name = msg.senderName { dict["sender"] = name }
                if let text = msg.text { dict["text"] = text }
                return dict
            }
            JSONOutput.printArray(items)
        } else {
            if messages.isEmpty {
                print("No messages found.")
                return
            }
            for msg in messages.reversed() {
                let sender = msg.isFromMe ? "Me" : (msg.senderName ?? "Unknown")
                let time = formatDate(msg.createdAt)
                let text = msg.text ?? "[\(msg.type)]"
                print("\(time) \(sender): \(text)")
            }
        }
    }
}

func parseDuration(_ str: String) -> Date? {
    let value: Double
    let unit: Character

    let trimmed = str.trimmingCharacters(in: .whitespaces).lowercased()
    guard let last = trimmed.last, last.isLetter else { return nil }
    guard let num = Double(trimmed.dropLast()) else { return nil }

    value = num
    unit = last

    let seconds: TimeInterval
    switch unit {
    case "s": seconds = value
    case "m": seconds = value * 60
    case "h": seconds = value * 3600
    case "d": seconds = value * 86400
    case "w": seconds = value * 604800
    default: return nil
    }

    return Date().addingTimeInterval(-seconds)
}
