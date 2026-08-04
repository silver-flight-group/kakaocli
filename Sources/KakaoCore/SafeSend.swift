import CryptoKit
import Darwin
import Foundation

public struct ChatID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int64
    public init(rawValue: Int64) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
}

public enum SendDestination: Hashable, Codable, Sendable {
    case chatID(ChatID)
    case selfChat

    fileprivate var storageKey: String {
        switch self {
        case .chatID(let id): return "chat:\(id.rawValue)"
        case .selfChat: return "self"
        }
    }
}

public struct SendRequest: Hashable, Codable, Sendable {
    public let requestID: UUID
    public let destination: SendDestination
    public let body: String

    public init(requestID: UUID, destination: SendDestination, body: String) {
        self.requestID = requestID
        self.destination = destination
        self.body = body
    }
}

public enum SendStatus: String, Codable, Sendable {
    case confirmed
    case unknown
}

public struct SendReceipt: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let chatID: ChatID
    public let logID: Int64?
    public let status: SendStatus
}

public enum SafeSendError: Error, CustomStringConvertible {
    case invalidRequest(String)
    case chatNotFound(ChatID)
    case selfChatNotFound
    case requestIDConflict(UUID)
    case state(String)

    public var description: String {
        switch self {
        case .invalidRequest(let message), .state(let message): return message
        case .chatNotFound(let id): return "Chat ID \(id) was not found"
        case .selfChatNotFound: return "Self-chat was not found"
        case .requestIDConflict(let id): return "Request ID \(id) was already used with different content"
        }
    }
}

protocol SafeSendDatabase: AnyObject, Sendable {
    func chat(id: Int64) throws -> Chat?
    func selfChat() throws -> Chat?
    func chatUIIdentityCount(displayName: String) throws -> Int
    func maxLogId(chatId: Int64) throws -> Int64
    func confirmedOutgoing(chatId: Int64, body: Data, after logId: Int64) throws -> Int64?
}

extension DatabaseReader: SafeSendDatabase {}

/// Synchronous implementation used by the CLI. The public actor below wraps
/// the same whole-transaction logic for concurrent library callers.
public final class SafeSendClient: @unchecked Sendable {
    public static let maximumBodyBytes = 64 * 1_024

    private let database: any SafeSendDatabase
    private let automator: any KakaoSubmitting
    private let paths: SendPaths
    private let confirmationAttempts: Int
    private let confirmationDelay: TimeInterval
    // Serializes every client in this process; flock below serializes other
    // processes for the same entire resolution/UI/confirmation transaction.
    private static let processLock = NSLock()

    public convenience init(
        database: DatabaseReader,
        automator: KakaoAutomator = KakaoAutomator(),
        stateDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli", isDirectory: true)
    ) {
        self.init(
            database: database,
            automator: automator,
            stateDirectory: stateDirectory,
            confirmationAttempts: 120,
            confirmationDelay: 0.1
        )
    }

    init(
        database: any SafeSendDatabase,
        automator: any KakaoSubmitting,
        stateDirectory: URL,
        confirmationAttempts: Int,
        confirmationDelay: TimeInterval
    ) {
        self.database = database
        self.automator = automator
        self.paths = SendPaths(stateDirectory: stateDirectory)
        self.confirmationAttempts = max(1, confirmationAttempts)
        self.confirmationDelay = max(0, confirmationDelay)
    }

    public func send(_ request: SendRequest) throws -> SendReceipt {
        let body = Data(request.body.utf8)
        guard !body.isEmpty else {
            throw SafeSendError.invalidRequest("Message must contain nonempty UTF-8")
        }
        guard body.count <= Self.maximumBodyBytes else {
            throw SafeSendError.invalidRequest(
                "Message exceeds \(Self.maximumBodyBytes) UTF-8 bytes"
            )
        }
        guard !body.contains(0) else {
            throw SafeSendError.invalidRequest("Message cannot contain NUL bytes")
        }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }

        try paths.prepare()
        let fileLock = try SendFileLock(path: paths.lock.path)
        try fileLock.lock()
        defer { fileLock.unlock() }

        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let store = SendReceiptStore(path: paths.receipts)
        if let stored = try store.attempt(requestID: request.requestID) {
            guard stored.destination == request.destination.storageKey,
                  stored.bodySHA256 == bodyHash else {
                throw SafeSendError.requestIDConflict(request.requestID)
            }
            // An unknown replay performs read-only reconciliation with the
            // original high-water mark and current request bytes. It never
            // invokes KakaoTalk a second time.
            if stored.receipt.status == .unknown,
               let highWatermark = stored.highWatermark,
               let logID = try database.confirmedOutgoing(
                   chatId: stored.receipt.chatID.rawValue,
                   body: body,
                   after: highWatermark
               ) {
                let confirmed = SendReceipt(
                    requestID: request.requestID,
                    chatID: stored.receipt.chatID,
                    logID: logID,
                    status: .confirmed
                )
                return try store.claimConfirmed(
                    destination: stored.destination,
                    bodySHA256: stored.bodySHA256,
                    highWatermark: highWatermark,
                    receipt: confirmed
                ) ? confirmed : stored.receipt
            }
            return stored.receipt
        }

        // Resolve the irreversible destination directly from the source DB on
        // every first attempt. Never trust a previously listed/cached Chat.
        let chat: Chat
        switch request.destination {
        case .chatID(let id):
            guard let resolved = try database.chat(id: id.rawValue) else {
                throw SafeSendError.chatNotFound(id)
            }
            chat = resolved
        case .selfChat:
            guard let resolved = try database.selfChat() else {
                throw SafeSendError.selfChatNotFound
            }
            chat = resolved
        }
        guard chat.displayName != "(unknown)",
              !chat.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SafeSendError.invalidRequest("The chat ID has no provable UI identity")
        }
        guard try database.chatUIIdentityCount(displayName: chat.displayName) == 1 else {
            throw SafeSendError.invalidRequest(
                "Chat ID \(chat.id) does not have a database-unique UI identity"
            )
        }

        let highWatermark = try database.maxLogId(chatId: chat.id)
        let provisional = SendReceipt(
            requestID: request.requestID,
            chatID: ChatID(rawValue: chat.id),
            logID: nil,
            status: .unknown
        )
        // Persist before the irreversible UI action. A crash from this point is
        // conservatively replayed as unknown instead of risking a duplicate.
        try store.save(
            destination: request.destination.storageKey,
            bodySHA256: bodyHash,
            highWatermark: highWatermark,
            receipt: provisional
        )
        do {
            try automator.submit(chat: chat, message: request.body)
        } catch AutomationError.preconditionFailed(let message) {
            // The automator proves this case occurs before submission and that
            // any text composed by this call was safely cleared.
            try store.remove(requestID: request.requestID)
            throw AutomationError.preconditionFailed(message)
        } catch AutomationError.outcomeUnknown {
            // Submission may have happened. Continue read-only confirmation;
            // never invoke the UI action again.
        } catch {
            // An unclassified transport error cannot prove that no action
            // occurred. Continue confirmation and conservatively keep the
            // durable unknown reservation.
        }

        for attempt in 0..<confirmationAttempts {
            do {
                if let logID = try database.confirmedOutgoing(
                    chatId: chat.id,
                    body: body,
                    after: highWatermark
                ) {
                    let confirmed = SendReceipt(
                        requestID: request.requestID,
                        chatID: ChatID(rawValue: chat.id),
                        logID: logID,
                        status: .confirmed
                    )
                    // If another request ID owns this exact DB row, the
                    // attribution is ambiguous. Keep this attempt unknown.
                    return try store.claimConfirmed(
                        destination: request.destination.storageKey,
                        bodySHA256: bodyHash,
                        highWatermark: highWatermark,
                        receipt: confirmed
                    ) ? confirmed : provisional
                }
            } catch {
                // A read or receipt-upgrade failure after the UI action has an
                // unknown outcome. The reservation prevents UI replay.
                return provisional
            }
            if attempt + 1 < confirmationAttempts, confirmationDelay > 0 {
                Thread.sleep(forTimeInterval: confirmationDelay)
            }
        }
        return provisional
    }
}

public actor KakaoClient {
    private let database: DatabaseReader
    private let sender: SafeSendClient

    public init(database: DatabaseReader, stateDirectory: URL? = nil) {
        self.database = database
        self.sender = SafeSendClient(
            database: database,
            stateDirectory: stateDirectory ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kakaocli", isDirectory: true)
        )
    }

    public func listChats(limit: Int = 50) throws -> [Chat] { try database.chats(limit: limit) }
    public func messages(chatID: ChatID? = nil, since: Date? = nil, limit: Int = 50) throws -> [Message] {
        try database.messages(chatId: chatID?.rawValue, since: since, limit: limit)
    }
    public func send(_ request: SendRequest) throws -> SendReceipt { try sender.send(request) }
}

struct SendPaths {
    let stateDirectory: URL
    var runDirectory: URL { stateDirectory.appendingPathComponent("run", isDirectory: true) }
    var lock: URL { runDirectory.appendingPathComponent("send.lock") }
    var receipts: URL { stateDirectory.appendingPathComponent("send-receipts.json") }

    func prepare() throws {
        for directory in [stateDirectory, runDirectory] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  chmod(directory.path, 0o700) == 0 else {
                throw SafeSendError.state("Could not secure send state directory")
            }
        }
    }
}

final class SendFileLock {
    private let descriptor: Int32

    init(path: String) throws {
        descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SafeSendError.state("Could not open the send lock")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            Darwin.close(descriptor)
            throw SafeSendError.state("Could not secure the send lock")
        }
    }

    deinit { Darwin.close(descriptor) }

    func lock() throws {
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SafeSendError.state("Could not acquire the send lock")
        }
    }

    func unlock() { _ = flock(descriptor, LOCK_UN) }
}

struct StoredSendAttempt: Codable {
    let destination: String
    let bodySHA256: String
    let highWatermark: Int64?
    let receipt: SendReceipt
}

final class SendReceiptStore {
    private let path: URL
    init(path: URL) { self.path = path }

    func attempt(requestID: UUID) throws -> StoredSendAttempt? {
        try load()[requestID.uuidString.lowercased()]
    }

    func save(
        destination: String,
        bodySHA256: String,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws {
        var values = try load()
        values[receipt.requestID.uuidString.lowercased()] = StoredSendAttempt(
            destination: destination,
            bodySHA256: bodySHA256,
            highWatermark: highWatermark,
            receipt: receipt
        )
        try write(values)
    }

    func claimConfirmed(
        destination: String,
        bodySHA256: String,
        highWatermark: Int64,
        receipt: SendReceipt
    ) throws -> Bool {
        guard let logID = receipt.logID, receipt.status == .confirmed else {
            throw SafeSendError.state("Only a confirmed receipt can claim a log row")
        }
        var values = try load()
        let alreadyOwned = values.values.contains { attempt in
            attempt.receipt.requestID != receipt.requestID
                && attempt.receipt.chatID == receipt.chatID
                && attempt.receipt.logID == logID
        }
        guard !alreadyOwned else { return false }
        values[receipt.requestID.uuidString.lowercased()] = StoredSendAttempt(
            destination: destination,
            bodySHA256: bodySHA256,
            highWatermark: highWatermark,
            receipt: receipt
        )
        try write(values)
        return true
    }

    func remove(requestID: UUID) throws {
        var values = try load()
        values.removeValue(forKey: requestID.uuidString.lowercased())
        try write(values)
    }

    private func load() throws -> [String: StoredSendAttempt] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let descriptor = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw SafeSendError.state("Could not open send receipts") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw SafeSendError.state("Send receipts are not a user-only regular file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = handle.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode([String: StoredSendAttempt].self, from: data)
        } catch {
            throw SafeSendError.state("Send receipts are corrupt or incompatible")
        }
    }

    private func write(_ values: [String: StoredSendAttempt]) throws {
        let data = try JSONEncoder().encode(values)
        let temporary = path.deletingLastPathComponent()
            .appendingPathComponent(".send-receipts.\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw SafeSendError.state("Could not create send receipts") }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { _ = unlink(temporary.path) }
        }

        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0,
              rename(temporary.path, path.path) == 0 else {
            throw SafeSendError.state("Could not persist send receipts")
        }
        shouldRemove = false
        let directory = path.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY
        )
        guard directoryDescriptor >= 0 else {
            throw SafeSendError.state("Could not open the send state directory for synchronization")
        }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw SafeSendError.state("Could not durably persist the send receipt directory entry")
        }
    }
}
