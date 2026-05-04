import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message via UI automation"
    )

    @Argument(help: "Chat name to send to (substring match), or any value with --self")
    var chat: String

    @Argument(help: "Message text to send")
    var message: String

    @Flag(name: [.customLong("me")], help: "Send to self-chat (나와의 채팅) regardless of chat argument")
    var selfChat = false

    @Flag(name: .long, help: "Show what would happen without actually sending")
    var dryRun = false

    @Option(name: .long, help: "Path to database file (auto-detected when chat is numeric)")
    var db: String?

    @Option(name: .long, help: "Database encryption key (auto-derived when chat is numeric)")
    var key: String?

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    func run() throws {
        let automator = KakaoAutomator()
        let target = selfChat ? "self-chat" : chat
        if dryRun {
            print("DRY RUN: Would send to '\(target)': \(message)")
            print("Steps: activate KakaoTalk → find chat '\(target)' → type message → press Enter")
            return
        }
        try AutomationPermissions.requireForSend()
        if !selfChat, let chatId = parseNumericChatId(chat) {
            let chatTarget = try resolveChatIdTarget(chatId)
            try automator.sendMessage(
                toChatAtIndex: chatTarget.rowIndex,
                targetDescription: chatTarget.description,
                message: message
            )
        } else {
            try automator.sendMessage(to: chat, message: message, selfChat: selfChat)
        }
        print("Message sent to '\(target)'.")
    }

    private struct ChatIdTarget {
        let rowIndex: Int
        let description: String
    }

    private func parseNumericChatId(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) else {
            return nil
        }
        return Int64(trimmed)
    }

    private func resolveChatIdTarget(_ chatId: Int64) throws -> ChatIdTarget {
        let (path, secureKey) = try resolveDatabasePath(dbPath: db, key: key, userId: userId)
        let reader = DatabaseReader(databasePath: path)
        try reader.open(key: secureKey)
        defer { reader.close() }

        let chats = try reader.chats(limit: 1000)
        guard let rowIndex = chats.firstIndex(where: { $0.id == chatId }) else {
            throw AutomationError.chatNotFound("\(chatId)")
        }
        let chat = chats[rowIndex]
        let name = chat.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = name.isEmpty || name == "(unknown)"
            ? "\(chatId)"
            : "\(name) [\(chatId)]"
        return ChatIdTarget(rowIndex: rowIndex, description: description)
    }
}
