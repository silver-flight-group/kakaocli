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
        // Reachability comes from the last harvest, not the database — the
        // grouping isn't stored here. Absent until a harvest has run.
        let metadata = MetadataStore()

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
                // Omitted rather than null when no harvest has run: absent means
                // "unknown", which is different from "known to be reachable".
                // false means the chat is inside a folder and `send` can't reach
                // it. The plain-text listing is deliberately left untouched —
                // downstream parsers key off its exact shape.
                if let present = metadata.info(for: chat.id)?.inTopLevelList {
                    dict["in_top_level_list"] = present
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
    let path: String
    let secureKey: String?

    if let dbPath {
        path = dbPath
        secureKey = key
    } else {
        let uuid = try DeviceInfo.platformUUID()

        // Try standard path: derive userId → derive dbName → find file
        if let uid = try? (userIdOverride ?? DeviceInfo.userId()) {
            let dbName = KeyDerivation.databaseName(userId: uid, uuid: uuid)
            let candidates = [
                "\(DeviceInfo.containerPath)/\(dbName)",
                "\(DeviceInfo.containerPath)/\(dbName).db",
            ]
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                path = found
                secureKey = key ?? KeyDerivation.secureKey(userId: uid, uuid: uuid)
                let reader = DatabaseReader(databasePath: path)
                try reader.open(key: secureKey)
                return reader
            }
        }

        // Fallback: scan for DB file, then try candidate userIds
        guard let discoveredPath = DeviceInfo.discoverDatabaseFile() else {
            let uid = try userIdOverride ?? DeviceInfo.userId()
            let dbName = KeyDerivation.databaseName(userId: uid, uuid: uuid)
            throw KakaoError.databaseNotFound("\(DeviceInfo.containerPath)/\(dbName)")
        }

        // Try provided key first
        if let key {
            path = discoveredPath
            secureKey = key
        } else {
            // Try each candidate userId to find the working key
            let candidateIds: [Int]
            if let override = userIdOverride {
                candidateIds = [override]
            } else {
                var ids = (try? DeviceInfo.userId()).map { [$0] } ?? []
                ids += DeviceInfo.candidateUserIds().filter { !ids.contains($0) }
                candidateIds = ids
            }

            var foundKey: String?
            for uid in candidateIds {
                let candidateKey = KeyDerivation.secureKey(userId: uid, uuid: uuid)
                let reader = DatabaseReader(databasePath: discoveredPath)
                if reader.tryOpen(key: candidateKey) {
                    reader.close()
                    foundKey = candidateKey
                    break
                }
            }

            path = discoveredPath
            secureKey = foundKey
        }
    }

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
