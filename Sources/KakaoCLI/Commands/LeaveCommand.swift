import ArgumentParser
import Foundation
import KakaoCore

struct LeaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leave",
        abstract: "Leave a KakaoTalk chatroom via UI automation"
    )

    @Argument(help: "Chat name to leave (substring match) or numeric chat ID")
    var chat: String

    @Flag(name: .long, help: "Show what would happen without actually leaving")
    var dryRun = false

    @Option(name: .long, help: "Path to database file (auto-detected when chat is numeric)")
    var db: String?

    @Option(name: .long, help: "Database encryption key (auto-derived when chat is numeric)")
    var key: String?

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    func run() throws {
        let automator = KakaoAutomator()
        let targetDescription: String
        let leaveAction: () throws -> Void

        if let chatId = parseNumericChatId(chat) {
            let target = try resolveChatIdTarget(chatId)
            targetDescription = target.description
            leaveAction = {
                if let exactChatName = target.exactChatName {
                    try automator.leaveChat(to: exactChatName)
                } else {
                    try automator.leaveChat(atChatIndex: target.rowIndex, targetDescription: target.description)
                }
            }
        } else {
            targetDescription = chat
            leaveAction = {
                try automator.leaveChat(to: chat)
            }
        }

        if dryRun {
            print("DRY RUN: Would leave chatroom '\(targetDescription)'")
            print("Steps: activate KakaoTalk -> find chat '\(targetDescription)' -> open menu -> Leave chatroom -> confirm")
            return
        }

        try AutomationPermissions.requireForSend()
        try leaveAction()
        print("Left chatroom '\(targetDescription)'.")
    }

    private struct ChatIdTarget {
        let rowIndex: Int
        let description: String
        let exactChatName: String?
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

        let metadata = MetadataStore()
        let chats = try reader.chats(limit: 1000)
        guard let rowIndex = chats.firstIndex(where: { $0.id == chatId }) else {
            throw AutomationError.chatNotFound("\(chatId)")
        }
        let chat = chats[rowIndex]
        let exactChatName = resolveExactChatName(
            chat: chat,
            chatId: chatId,
            reader: reader,
            metadata: metadata
        )
        let description = exactChatName.map { "\($0) [\(chatId)]" } ?? "\(chatId)"
        return ChatIdTarget(
            rowIndex: rowIndex,
            description: description,
            exactChatName: exactChatName
        )
    }

    private func resolveExactChatName(
        chat: Chat,
        chatId: Int64,
        reader: DatabaseReader,
        metadata: MetadataStore
    ) -> String? {
        let knownName = preferredChatDisplayName(for: chat, metadata: metadata)
        if !isUnknownChatDisplayName(knownName) {
            return knownName
        }
        do {
            let options = ChatHarvester.Options(
                maxChats: 0,
                namesOnly: true,
                skipUnread: false
            )
            _ = try ChatHarvester.harvest(
                db: reader,
                metadata: metadata,
                options: options,
                progress: { _ in }
            )
            try metadata.save()
        } catch {
            return nil
        }
        let refreshedName = preferredChatDisplayName(
            databaseDisplayName: chat.displayName,
            metadataDisplayName: metadata.name(for: chatId)
        )
        return isUnknownChatDisplayName(refreshedName) ? nil : refreshedName
    }
}
