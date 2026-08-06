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

    func run() throws {
        let (path, secureKey) = try resolveDatabasePath(dbPath: db, key: key)

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
            startFromLogId: sinceLogId
        )

        // Handle Ctrl-C gracefully
        signal(SIGINT) { _ in
            fputs("\nStopping sync...\n", stderr)
            Darwin.exit(0)
        }

        fputs("Watching for new messages (poll every \(interval)s)...\n", stderr)

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
func resolveDatabasePath(dbPath: String?, key: String?) throws -> (path: String, key: String?) {
    if let dbPath {
        return (dbPath, key)
    }
    let uuid = try DeviceInfo.platformUUID()

    // Try standard path: derive userId → derive dbName → find file → verify it actually opens.
    // A file existing at the derived name is not proof the derived key is right — if this Mac
    // has been used by more than one employee/KakaoTalk account, stale plist state can make
    // userId() resolve to a *previous* account whose leftover encrypted DB still happens to be
    // on disk. Opening it is the only real check; if it fails we must not trust this branch.
    if key == nil, let uid = try? DeviceInfo.userId() {
        let dbName = KeyDerivation.databaseName(userId: uid, uuid: uuid)
        let candidates = [
            "\(DeviceInfo.containerPath)/\(dbName)",
            "\(DeviceInfo.containerPath)/\(dbName).db",
        ]
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let secureKey = KeyDerivation.secureKey(userId: uid, uuid: uuid)
            let reader = DatabaseReader(databasePath: found)
            if reader.tryOpen(key: secureKey) {
                reader.close()
                return (found, secureKey)
            }
            // Derived key didn't actually open the file — fall through to the
            // discover+candidate search below instead of returning a wrong key.
        }
    }

    // Fallback: scan for every DB file this container holds (there can be more than one — see
    // above) and try every candidate userId's key against each until one actually opens.
    let discoveredPaths = DeviceInfo.discoverDatabaseFiles()
    guard !discoveredPaths.isEmpty else {
        let uid = try DeviceInfo.userId()
        let dbName = KeyDerivation.databaseName(userId: uid, uuid: uuid)
        throw KakaoError.databaseNotFound("\(DeviceInfo.containerPath)/\(dbName)")
    }

    if let key {
        return (discoveredPaths[0], key)
    }

    var candidateIds = (try? DeviceInfo.userId()).map { [$0] } ?? [Int]()
    candidateIds += DeviceInfo.candidateUserIds().filter { !candidateIds.contains($0) }

    for path in discoveredPaths {
        for uid in candidateIds {
            let candidateKey = KeyDerivation.secureKey(userId: uid, uuid: uuid)
            let reader = DatabaseReader(databasePath: path)
            if reader.tryOpen(key: candidateKey) {
                reader.close()
                return (path, candidateKey)
            }
        }
    }

    // Nothing opened — return the first discovered path without a key so the caller
    // still gets a clear decryption error instead of a silent wrong-key failure.
    return (discoveredPaths[0], nil)
}
