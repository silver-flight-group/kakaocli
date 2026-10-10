import ArgumentParser
import Foundation
import KakaoCore

struct HarvestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harvest",
        abstract: "Capture chat names and load message history from KakaoTalk UI",
        discussion: """
            Reads the KakaoTalk UI chat list to capture proper display names
            that may be missing from the database (especially group chats).
            Names are saved to ~/.kakaocli/metadata.json for use by other commands.

            Use --scroll to open each chat, scroll to top, and click
            "View Previous Chats" to load as much history as the server allows.
            If the Talk Drive Plus paywall appears, it is dismissed and the
            command moves on to the next chat.
            """
    )

    @Option(name: .long, help: "Process top N most recent chats (default: all)")
    var top: Int = 0

    @Flag(name: .long, help: "Open chats and load history via scroll + View Previous Chats")
    var scroll = false

    @Option(name: .long, help: "Max 'View Previous Chats' clicks per chat (default: 10)")
    var maxClicks: Int = 10

    @Option(name: .long, help: "Delay between actions in seconds (default: 1.5)")
    var scrollDelay: Double = 1.5

    @Flag(name: .long, help: "Show what would be done without doing it")
    var dryRun = false

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    func run() throws {
        let (path, secureKey) = try resolveDatabasePath(dbPath: db, key: key)
        let reader = DatabaseReader(databasePath: path)
        try reader.open(key: secureKey)
        defer { reader.close() }

        let metadata = MetadataStore()
        if let error = metadata.loadError { throw error }

        if dryRun {
            let limit = top > 0 ? top : 1000
            let chats = try reader.chats(limit: limit)
            fputs("DRY RUN: Would process \(chats.count) chats\n", stderr)
            for (i, chat) in chats.enumerated() {
                let existing = metadata.name(for: chat.id)
                let nameInfo = existing.map { " (metadata: \($0))" } ?? ""
                let unread = chat.unreadCount > 0 ? " [SKIP: \(chat.unreadCount) unread]" : ""
                fputs("  [\(i+1)] \(chat.displayName)\(nameInfo)\(unread)\n", stderr)
            }
            fputs("\nMetadata store: \(metadata.count) entries at ~/.kakaocli/metadata.json\n", stderr)
            return
        }

        let options = ChatHarvester.Options(
            maxChats: top,
            maxPreviousClicks: maxClicks,
            namesOnly: !scroll,
            scrollDelay: scrollDelay
        )

        let results = try ChatHarvester.harvest(
            db: reader,
            metadata: metadata,
            options: options,
            progress: { msg in fputs("\(msg)\n", stderr) }
        )

        // Save metadata
        try metadata.save()

        // Print summary to stderr
        fputs("\n=== Harvest Summary ===\n", stderr)
        var totalNew = 0
        var processed = 0
        var skipped = 0
        for r in results {
            let delta = r.messagesAfter - r.messagesBefore
            totalNew += delta
            if r.skipped {
                skipped += 1
            } else {
                processed += 1
            }
            let status: String
            if r.skipped {
                status = "skipped (\(r.skipReason ?? ""))"
            } else if delta > 0 {
                status = "+\(delta) messages (\(r.messagesBefore) → \(r.messagesAfter))"
            } else {
                status = "\(r.messagesAfter) msgs"
            }
            fputs("  \(r.uiName): \(status)\n", stderr)
        }
        fputs("\nProcessed: \(processed), Skipped: \(skipped)\n", stderr)
        if scroll {
            fputs("Total new messages loaded: \(totalNew)\n", stderr)
        }
        fputs("Metadata saved: \(metadata.count) chats → ~/.kakaocli/metadata.json\n", stderr)

        // JSON output to stdout
        struct ResultEntry: Encodable {
            let chatId: String
            let name: String
            let messagesBefore: Int
            let messagesAfter: Int
            let newMessages: Int
            let skipped: Bool
        }
        let output = results.map { r in
            ResultEntry(
                chatId: "\(r.chatId)",
                name: r.uiName,
                messagesBefore: r.messagesBefore,
                messagesAfter: r.messagesAfter,
                newMessages: r.messagesAfter - r.messagesBefore,
                skipped: r.skipped
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let json = try? encoder.encode(output),
           let str = String(data: json, encoding: .utf8) {
            print(str)
        }
    }
}
