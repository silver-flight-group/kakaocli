import Foundation

/// Persistent metadata store for KakaoTalk chat names and harvest info.
/// Stored at ~/.kakaocli/metadata.json
public final class MetadataStore {

    public struct ChatInfo: Codable {
        public var displayName: String
        public var memberCount: Int?
        public var chatType: Int?
        public var lastHarvested: Date?
        public var messageCount: Int?
    }

    private let fileURL: URL
    private var chats: [String: ChatInfo]

    /// A load failure blocks saving so corrupt or unreadable metadata is never
    /// replaced by a silently empty store. Reopen the store after repairing it.
    public private(set) var loadError: Error?

    public convenience init() {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli/metadata.json")
        self.init(fileURL: fileURL)
    }

    /// A separate location keeps unit tests isolated from the user's metadata.
    init(fileURL: URL) {
        self.fileURL = fileURL
        chats = [:]
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            chats = try decoder.decode([String: ChatInfo].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A store that has not been created yet starts empty.
        } catch {
            loadError = error
        }
    }

    public func name(for chatId: Int64) -> String? {
        chats[String(chatId)]?.displayName
    }

    public func info(for chatId: Int64) -> ChatInfo? {
        chats[String(chatId)]
    }

    public func update(chatId: Int64, name: String, memberCount: Int? = nil,
                       chatType: Int? = nil, messageCount: Int? = nil) {
        let key = String(chatId)
        var existing = chats[key] ?? ChatInfo(displayName: name)
        existing.displayName = name
        existing.lastHarvested = Date()
        if let memberCount { existing.memberCount = memberCount }
        if let chatType { existing.chatType = chatType }
        if let messageCount { existing.messageCount = messageCount }
        chats[key] = existing
    }

    public func save() throws {
        if let loadError { throw loadError }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chats)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public var allChats: [String: ChatInfo] {
        chats
    }

    public var count: Int { chats.count }
}

