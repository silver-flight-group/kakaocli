import ArgumentParser
import Foundation
import KakaoCore

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Watch for new messages and output as JSON (for AI agents)"
    )

    @Flag(name: .long, help: "Continuously watch for new messages (NDJSON output)")
    var follow = false

    @Option(name: .long, help: "POST new messages to this webhook URL")
    var webhook: String?

    @Option(name: .long, help: "Poll interval in seconds (default: 2)")
    var interval: Double = 2.0

    @Option(name: .long, help: "Start from this logId (default: latest)")
    var sinceLogId: Int64?

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    @Option(name: .long, help: "Only emit group chat messages that start with this mention tag; direct chats are unaffected. May be repeated.")
    var groupMentionTag: [String] = []

    func run() throws {
        let (path, secureKey) = try resolveDatabasePath(dbPath: db, key: key, userId: userId)
        let groupMentionTags = groupMentionTag
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !follow && webhook == nil {
            // One-shot: show current high-water mark
            let reader = DatabaseReader(databasePath: path)
            try reader.open(key: secureKey)
            defer { reader.close() }
            let maxId = try reader.maxLogId()
            print("{\"status\":\"ready\",\"max_log_id\":\(maxId)}")
            return
        }

        let webhookPublisher: WebhookPublisher?
        if let webhookUrl = webhook, let url = URL(string: webhookUrl) {
            webhookPublisher = WebhookPublisher(url: url)
            fputs("Webhook: \(webhookUrl)\n", stderr)
        } else {
            webhookPublisher = nil
        }

        let watcher = DatabaseWatcher(
            databasePath: path,
            key: secureKey,
            pollInterval: interval,
            startFromLogId: sinceLogId,
            groupMentionTags: groupMentionTags
        )

        // Handle Ctrl-C gracefully
        signal(SIGINT) { _ in
            fputs("\nStopping sync...\n", stderr)
            Darwin.exit(0)
        }

        fputs("Watching for new messages (poll every \(interval)s)...\n", stderr)
        if !groupMentionTags.isEmpty {
            let filterDescription = groupMentionTags.joined(separator: ", ")
            fputs("Group mention filter: \(filterDescription)\n", stderr)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        watcher.watch(
            onMessages: { messages in
                for msg in messages {
                    // NDJSON: one JSON object per line
                    if let data = try? encoder.encode(msg),
                       let line = String(data: data, encoding: .utf8) {
                        print(line)
                        fflush(stdout)
                    }
                }
                // Also publish to webhook if configured
                if let publisher = webhookPublisher {
                    if !publisher.publish(messages) {
                        fputs("Warning: webhook delivery failed\n", stderr)
                    }
                }
            },
            onError: { error in
                fputs("Error: \(error)\n", stderr)
            }
        )
    }
}

/// Resolve database path and key without opening the database.
func resolveDatabasePath(dbPath: String?, key: String?, userId userIdOverride: Int? = nil) throws -> (path: String, key: String?) {
    if let dbPath {
        return (dbPath, key)
    }
    let uuid = try DeviceInfo.platformUUID()

    // Try standard path: derive userId → derive dbName → find file
    if let uid = try? (userIdOverride ?? DeviceInfo.userId()) {
        let dbName = KeyDerivation.databaseName(userId: uid, uuid: uuid)
        let candidates = [
            "\(DeviceInfo.containerPath)/\(dbName)",
            "\(DeviceInfo.containerPath)/\(dbName).db",
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let secureKey = key ?? KeyDerivation.secureKey(userId: uid, uuid: uuid)
            return (found, secureKey)
        }
    }

    // Fallback: scan for DB file, try candidate userIds for the key
    guard let discoveredPath = DeviceInfo.discoverDatabaseFile() else {
        let uid = try userIdOverride ?? DeviceInfo.userId()
        let dbName = KeyDerivation.databaseName(userId: uid, uuid: uuid)
        throw KakaoError.databaseNotFound("\(DeviceInfo.containerPath)/\(dbName)")
    }

    if let key {
        return (discoveredPath, key)
    }

    // Try candidate userIds to find a working key
    let candidateIds: [Int]
    if let override = userIdOverride {
        candidateIds = [override]
    } else {
        var ids = (try? DeviceInfo.userId()).map { [$0] } ?? [Int]()
        ids += DeviceInfo.candidateUserIds().filter { !ids.contains($0) }
        candidateIds = ids
    }
    for uid in candidateIds {
        let candidateKey = KeyDerivation.secureKey(userId: uid, uuid: uuid)
        let reader = DatabaseReader(databasePath: discoveredPath)
        if reader.tryOpen(key: candidateKey) {
            reader.close()
            return (discoveredPath, candidateKey)
        }
    }

    // Return the discovered path without a key — caller will get a decryption error
    return (discoveredPath, nil)
}
