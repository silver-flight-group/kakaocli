import CryptoKit
import Darwin
import Foundation
import Testing
@testable import KakaoCore

@Suite("Safe send transaction")
struct SafeSendClientTests {
    private var target: Chat {
        Chat(
            id: 42,
            type: .direct,
            displayName: "Exact Target",
            memberCount: 2,
            lastMessageId: 8,
            lastMessageAt: nil,
            unreadCount: 0,
            isSelfChat: false
        )
    }

    @Test("confirmation is bound to exact target, bytes, and high-water mark")
    func exactConfirmation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MockSendDatabase(chat: target)
        database.confirmedLogID = 99
        let ui = MockSubmitter()
        let client = makeClient(database: database, ui: ui, root: root)
        let request = SendRequest(
            requestID: UUID(),
            destination: .chatID(ChatID(rawValue: target.id)),
            body: "byte-exact 🫧"
        )

        let receipt = try client.send(request)
        #expect(receipt.status == .confirmed)
        #expect(receipt.logID == 99)
        #expect(database.confirmationChatID == target.id)
        #expect(database.confirmationBody == Data(request.body.utf8))
        #expect(database.confirmationAfter == 8)
        #expect(ui.calls == 1)
    }

    @Test("duplicate database display identity fails before UI work")
    func duplicateIdentity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MockSendDatabase(chat: target)
        database.identityCount = 2
        let ui = MockSubmitter()
        let client = makeClient(database: database, ui: ui, root: root)

        #expect(throws: SafeSendError.self) {
            try client.send(
                SendRequest(
                    requestID: UUID(),
                    destination: .chatID(ChatID(rawValue: target.id)),
                    body: "ambiguous"
                )
            )
        }
        #expect(ui.calls == 0)
    }

    @Test("UI uncertainty still receives read-only database confirmation")
    func uncertainConfirmation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MockSendDatabase(chat: target)
        database.confirmedLogID = 101
        let ui = MockSubmitter()
        ui.error = AutomationError.outcomeUnknown("AX acknowledgement unavailable")
        let client = makeClient(database: database, ui: ui, root: root)

        let receipt = try client.send(
            SendRequest(
                requestID: UUID(),
                destination: .chatID(ChatID(rawValue: target.id)),
                body: "confirm only"
            )
        )
        #expect(receipt.status == .confirmed)
        #expect(receipt.logID == 101)
        #expect(ui.calls == 1)
        #expect(database.confirmationCalls == 1)
    }

    @Test("post-action transport and confirmation errors remain durable unknowns")
    func postActionErrors() throws {
        struct UnexpectedTransportError: Error {}

        let transportRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: transportRoot) }
        let transportDatabase = MockSendDatabase(chat: target)
        let transportUI = MockSubmitter()
        transportUI.error = UnexpectedTransportError()
        let transportClient = makeClient(
            database: transportDatabase, ui: transportUI, root: transportRoot
        )
        let transportRequest = SendRequest(
            requestID: UUID(),
            destination: .chatID(ChatID(rawValue: target.id)),
            body: "transport uncertain"
        )
        #expect(try transportClient.send(transportRequest).status == .unknown)
        #expect(try transportClient.send(transportRequest).status == .unknown)
        #expect(transportUI.calls == 1)

        let confirmationRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: confirmationRoot) }
        let confirmationDatabase = MockSendDatabase(chat: target)
        confirmationDatabase.confirmationError = SafeSendError.state("read failed")
        let confirmationUI = MockSubmitter()
        let confirmationClient = makeClient(
            database: confirmationDatabase, ui: confirmationUI, root: confirmationRoot
        )
        let confirmationRequest = SendRequest(
            requestID: UUID(),
            destination: .chatID(ChatID(rawValue: target.id)),
            body: "confirmation uncertain"
        )
        #expect(try confirmationClient.send(confirmationRequest).status == .unknown)
        #expect(confirmationUI.calls == 1)
    }

    @Test("stored unknown reconciles later without another UI action")
    func lateConfirmation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MockSendDatabase(chat: target)
        let ui = MockSubmitter()
        let client = makeClient(database: database, ui: ui, root: root)
        let request = SendRequest(
            requestID: UUID(),
            destination: .chatID(ChatID(rawValue: target.id)),
            body: "arrives later"
        )

        #expect(try client.send(request).status == .unknown)
        database.confirmedLogID = 104
        let reconciled = try client.send(request)
        #expect(reconciled.status == .confirmed)
        #expect(reconciled.logID == 104)
        #expect(ui.calls == 1)
        #expect(database.resolveCalls == 1)
    }

    @Test("precondition failure clears reservation for a same-ID retry")
    func preconditionRetry() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = MockSendDatabase(chat: target)
        database.confirmedLogID = 105
        let ui = MockSubmitter()
        ui.error = AutomationError.preconditionFailed("not ready")
        let client = makeClient(database: database, ui: ui, root: root)
        let request = SendRequest(
            requestID: UUID(),
            destination: .chatID(ChatID(rawValue: target.id)),
            body: "retry safely"
        )

        #expect(throws: AutomationError.self) { try client.send(request) }
        ui.error = nil
        #expect(try client.send(request).status == .confirmed)
        #expect(ui.calls == 2)
    }

    @Test("request IDs cannot be reused with different content")
    func requestConflict() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeClient(
            database: MockSendDatabase(chat: target),
            ui: MockSubmitter(),
            root: root
        )
        let id = UUID()
        _ = try client.send(
            SendRequest(
                requestID: id,
                destination: .chatID(ChatID(rawValue: target.id)),
                body: "first"
            )
        )
        #expect(throws: SafeSendError.self) {
            try client.send(
                SendRequest(
                    requestID: id,
                    destination: .chatID(ChatID(rawValue: target.id)),
                    body: "second"
                )
            )
        }
    }

    @Test("oversized and NUL-containing bodies fail before state or UI work")
    func bodyLimits() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ui = MockSubmitter()
        let client = makeClient(
            database: MockSendDatabase(chat: target),
            ui: ui,
            root: root
        )
        for body in [
            String(repeating: "a", count: SafeSendClient.maximumBodyBytes + 1),
            "unsafe\0body",
        ] {
            #expect(throws: SafeSendError.self) {
                try client.send(
                    SendRequest(
                        requestID: UUID(),
                        destination: .chatID(ChatID(rawValue: target.id)),
                        body: body
                    )
                )
            }
        }
        #expect(ui.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("run").path))
    }

    @Test("one confirmed log row has one durable request owner")
    func logOwnership() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SendPaths(stateDirectory: root)
        try paths.prepare()
        let store = SendReceiptStore(path: paths.receipts)
        let firstID = UUID()
        let secondID = UUID()
        let hash = SHA256.hash(data: Data("same".utf8)).map { String(format: "%02x", $0) }.joined()
        for requestID in [firstID, secondID] {
            try store.save(
                destination: "chat:42",
                bodySHA256: hash,
                highWatermark: 8,
                receipt: SendReceipt(
                    requestID: requestID,
                    chatID: ChatID(rawValue: 42),
                    logID: nil,
                    status: .unknown
                )
            )
        }
        #expect(try store.claimConfirmed(
            destination: "chat:42",
            bodySHA256: hash,
            highWatermark: 8,
            receipt: SendReceipt(
                requestID: firstID,
                chatID: ChatID(rawValue: 42),
                logID: 99,
                status: .confirmed
            )
        ))
        #expect(try !store.claimConfirmed(
            destination: "chat:42",
            bodySHA256: hash,
            highWatermark: 8,
            receipt: SendReceipt(
                requestID: secondID,
                chatID: ChatID(rawValue: 42),
                logID: 99,
                status: .confirmed
            )
        ))
        #expect(try store.attempt(requestID: firstID)?.receipt.status == .confirmed)
        #expect(try store.attempt(requestID: secondID)?.receipt.status == .unknown)

        let permissions = try FileManager.default.attributesOfItem(atPath: paths.receipts.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("the lock rejects symlinks and excludes another process")
    func hardenedCrossProcessLock() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SendPaths(stateDirectory: root)
        try paths.prepare()
        let unrelated = root.appendingPathComponent("unrelated")
        #expect(FileManager.default.createFile(atPath: unrelated.path, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(at: paths.lock, withDestinationURL: unrelated)
        #expect(throws: SafeSendError.self) { try SendFileLock(path: paths.lock.path) }
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))

        try FileManager.default.removeItem(at: paths.lock)
        let lock = try SendFileLock(path: paths.lock.path)
        try lock.lock()
        #expect(try pythonCanLock(path: paths.lock.path) == false)
        lock.unlock()
        #expect(try pythonCanLock(path: paths.lock.path) == true)
    }

    @Test("concurrent callers sharing one client never overlap UI transactions")
    func sameInstanceSerialization() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ui = ConcurrentSubmitter()
        let client = makeClient(
            database: MockSendDatabase(chat: target),
            ui: ui,
            root: root
        )
        let group = DispatchGroup()
        let errors = ErrorBox()
        for body in ["first", "second"] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try client.send(
                        SendRequest(
                            requestID: UUID(),
                            destination: .chatID(ChatID(rawValue: 42)),
                            body: body
                        )
                    )
                } catch {
                    errors.append(error)
                }
            }
        }
        #expect(group.wait(timeout: .now() + 3) == .success)
        #expect(errors.values.isEmpty)
        #expect(ui.calls == 2)
        #expect(ui.maximumConcurrentCalls == 1)
    }

    private func makeClient(
        database: any SafeSendDatabase,
        ui: any KakaoSubmitting,
        root: URL
    ) -> SafeSendClient {
        SafeSendClient(
            database: database,
            automator: ui,
            stateDirectory: root,
            confirmationAttempts: 1,
            confirmationDelay: 0
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func pythonCanLock(path: String) throws -> Bool {
        let script = """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            sys.exit(0)
        except BlockingIOError:
            sys.exit(1)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private final class MockSendDatabase: SafeSendDatabase, @unchecked Sendable {
    let resolvedChat: Chat?
    var selfResolvedChat: Chat?
    var identityCount = 1
    var highWatermark: Int64 = 8
    var confirmedLogID: Int64?
    var confirmationChatID: Int64?
    var confirmationBody: Data?
    var confirmationAfter: Int64?
    var confirmationCalls = 0
    var confirmationError: Error?
    var resolveCalls = 0

    init(chat: Chat?) {
        self.resolvedChat = chat
        self.selfResolvedChat = chat?.isSelfChat == true ? chat : nil
    }

    func chat(id: Int64) throws -> Chat? {
        resolveCalls += 1
        return resolvedChat?.id == id ? resolvedChat : nil
    }

    func selfChat() throws -> Chat? {
        resolveCalls += 1
        return selfResolvedChat
    }

    func chatUIIdentityCount(displayName _: String) throws -> Int { identityCount }
    func maxLogId(chatId _: Int64) throws -> Int64 { highWatermark }

    func confirmedOutgoing(chatId: Int64, body: Data, after logId: Int64) throws -> Int64? {
        confirmationCalls += 1
        confirmationChatID = chatId
        confirmationBody = body
        confirmationAfter = logId
        if let confirmationError { throw confirmationError }
        return confirmedLogID
    }
}

private final class MockSubmitter: KakaoSubmitting, @unchecked Sendable {
    var calls = 0
    var error: Error?

    func submit(chat _: Chat, message _: String) throws {
        calls += 1
        if let error { throw error }
    }
}

private final class ConcurrentSubmitter: KakaoSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var calls = 0
    private(set) var maximumConcurrentCalls = 0

    func submit(chat _: Chat, message _: String) throws {
        lock.lock()
        calls += 1
        active += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, active)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}
