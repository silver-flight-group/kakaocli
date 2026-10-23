import ArgumentParser
import Foundation
import KakaoCore

struct ChatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List all chats"
    )

    @Option(name: .long, help: "Maximum number of chats to show")
    var limit: Int = 50

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Path to database file (auto-detected if not set)")
    var db: String?

    @Option(name: .long, help: "Database encryption key (auto-derived if not set)")
    var key: String?

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key)
        defer { reader.close() }

        let chats = try reader.chats(limit: limit)

        if json {
            let items = chats.map { chat -> [String: Any] in
                var dict: [String: Any] = [
                    "id": chat.id,
                    "type": chat.type.rawValue,
                    "display_name": chat.displayName,
                    "member_count": chat.memberCount,
                    "unread_count": chat.unreadCount,
                ]
                if let ts = chat.lastMessageAt {
                    dict["last_message_at"] = ISO8601DateFormatter().string(from: ts)
                }
                return dict
            }
            JSONOutput.printArray(items)
        } else {
            if chats.isEmpty {
                print("No chats found.")
                return
            }
            for chat in chats {
                let unread = chat.unreadCount > 0 ? " (\(chat.unreadCount) unread)" : ""
                let time = chat.lastMessageAt.map { formatDate($0) } ?? ""
                print("[\(chat.id)] \(chat.displayName)\(unread) \(time)")
            }
        }
    }
}

func openDatabase(dbPath: String?, key: String?, userId userIdOverride: Int? = nil) throws -> DatabaseReader {
    let (path, secureKey) = try resolveDatabasePath(dbPath: dbPath, key: key, userId: userIdOverride)
    let reader = DatabaseReader(databasePath: path)
    try reader.open(key: secureKey)
    return reader
}

func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
    } else if calendar.isDateInYesterday(date) {
        return "yesterday"
    } else {
        formatter.dateFormat = "MM/dd"
    }
    return formatter.string(from: date)
}
