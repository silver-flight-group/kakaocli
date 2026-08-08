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
        /// Whether this chat has a row in KakaoTalk's **top-level** chat list.
        ///
        /// False means it is collapsed inside a folder — in practice "Silent
        /// Chatroom" — and therefore cannot be reached by `AXHelpers.findChatRow`,
        /// so `send` will fail for it. Recorded because the grouping exists
        /// nowhere else on this machine: no `NTChatRoom` column, `NTChatFolder`
        /// row, `NTSetting` key or container plist distinguishes those chats, and
        /// `pushAlert = 0` catches only the muted subset. The only way to know is
        /// to compare the database against the visible list, which is exactly
        /// what a harvest does — so it records the answer here.
        ///
        /// nil = never harvested; treat as unknown, not as reachable.
        public var inTopLevelList: Bool?
        /// When `inTopLevelList` was last determined.
        public var listCheckedAt: Date?
    }

    private let filePath: String
    private var chats: [String: ChatInfo]

    public init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        filePath = dir.appendingPathComponent("metadata.json").path

        // The decoder must mirror save()'s .iso8601 date strategy. It didn't:
        // save() wrote dates as ISO8601 strings while this used JSONDecoder's
        // default .deferredToDate, which expects a number. Every load therefore
        // threw on the first `lastHarvested` and fell through to an empty store,
        // silently — so metadata.json has been write-only since it was added,
        // and `harvest --dry-run` never showed the "(metadata: …)" annotations
        // it prints for known chats.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = FileManager.default.contents(atPath: filePath),
           let decoded = try? decoder.decode([String: ChatInfo].self, from: data) {
            chats = decoded
        } else {
            chats = [:]
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

    /// Record whether a chat is in the top-level list. Kept separate from
    /// `update` because it is derived differently: `update` describes a chat a
    /// harvest *saw*, while this must also be written for every chat it did
    /// **not** see — absence from the visible list is the whole signal.
    public func setInTopLevelList(chatId: Int64, _ present: Bool, name: String? = nil) {
        let key = String(chatId)
        var existing = chats[key] ?? ChatInfo(displayName: name ?? "(unknown)")
        if let name, !name.isEmpty, existing.displayName == "(unknown)" {
            existing.displayName = name
        }
        existing.inTopLevelList = present
        existing.listCheckedAt = Date()
        chats[key] = existing
    }

    /// Chats a harvest confirmed are **not** in the top-level list — i.e. inside
    /// a folder, where `send` cannot reach them. Empty if never harvested.
    public var unreachableChats: [(id: Int64, name: String)] {
        chats.compactMap { key, info in
            guard info.inTopLevelList == false, let id = Int64(key) else { return nil }
            return (id, info.displayName)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(chats)
        try data.write(to: URL(fileURLWithPath: filePath))
    }

    public var allChats: [String: ChatInfo] {
        chats
    }

    public var count: Int { chats.count }
}
