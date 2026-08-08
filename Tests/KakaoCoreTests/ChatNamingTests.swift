import Foundation
import Testing
@testable import KakaoCore

// MARK: - Chat display names
//
// The name KakaoTalk shows is assembled from five sources in a fixed order.
// Getting that order wrong is not a cosmetic bug: `send` addresses chats *by
// name*, so a chat named wrongly is a chat that can't be reached.

private let users: [Int64: String] = [1: "Alice", 2: "Bob", 3: "Me"]

@Test func chatNamePrefersRoomNameOverEverything() {
    // Found the hard way: with the meta title ahead of chatName, a chat the app
    // calls "Korean LLC for Junipera" came out as "D8 visa".
    let name = DatabaseReader.chatDisplayName(
        chatName: "Room Name", metaTitle: "Meta Title", linkName: "Link Name",
        directPartner: "Alice", memberIds: nil, users: users, selfUserId: 3
    )
    #expect(name == "Room Name")
}

@Test func chatNameFallsBackThroughMetaThenLinkThenPartner() {
    #expect(DatabaseReader.chatDisplayName(
        chatName: nil, metaTitle: "Meta Title", linkName: "Link Name",
        directPartner: "Alice", memberIds: nil, users: users, selfUserId: 3
    ) == "Meta Title")

    // Open chats carry their name only on the link row.
    #expect(DatabaseReader.chatDisplayName(
        chatName: nil, metaTitle: nil, linkName: "Link Name",
        directPartner: "Alice", memberIds: nil, users: users, selfUserId: 3
    ) == "Link Name")

    #expect(DatabaseReader.chatDisplayName(
        chatName: nil, metaTitle: nil, linkName: nil,
        directPartner: "Alice", memberIds: nil, users: users, selfUserId: 3
    ) == "Alice")
}

@Test func emptyStringsAreSkippedNotUsed() {
    // The database stores "" rather than NULL in several of these columns.
    #expect(DatabaseReader.chatDisplayName(
        chatName: "", metaTitle: "", linkName: "", directPartner: "Alice",
        memberIds: nil, users: users, selfUserId: 3
    ) == "Alice")
}

@Test func unnamedGroupIsNamedByMembersSortedAndWithoutSelf() throws {
    // Sorted by user id, which is the order the app displays them in — sorting
    // the other way produced "Bob, Alice" where KakaoTalk shows "Alice, Bob".
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [NSNumber(value: 2), NSNumber(value: 3), NSNumber(value: 1)],
        format: .binary, options: 0
    )
    let name = DatabaseReader.chatDisplayName(
        chatName: nil, metaTitle: nil, linkName: nil, directPartner: nil,
        memberIds: plist, users: users, selfUserId: 3
    )
    #expect(name == "Alice, Bob")
}

@Test func chatWithNoNameAnywhereIsUnknown() throws {
    // A room whose only member is you: nothing to name it with.
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [NSNumber(value: 3)], format: .binary, options: 0
    )
    #expect(DatabaseReader.chatDisplayName(
        chatName: nil, metaTitle: nil, linkName: nil, directPartner: nil,
        memberIds: plist, users: users, selfUserId: 3
    ) == "(unknown)")
}

@Test func decodeMemberIdsHandlesBinaryPlistAndJunk() throws {
    let plist = try PropertyListSerialization.data(
        fromPropertyList: [NSNumber(value: 10), NSNumber(value: 20)],
        format: .binary, options: 0
    )
    #expect(DatabaseReader.decodeMemberIds(plist) == [10, 20])
    #expect(DatabaseReader.decodeMemberIds(Data()) == nil)
    #expect(DatabaseReader.decodeMemberIds(Data("not a plist".utf8)) == nil)
}

// MARK: - Metadata persistence
//
// Regression test for a bug that was silent for the store's whole life: save()
// encoded dates as .iso8601 while init decoded with a default JSONDecoder, so
// every load threw on the first date and fell back to an empty store. Nothing
// ever noticed, because nothing round-tripped it.

@Test func metadataSurvivesARoundTrip() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("kakaocli-metadata-test-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = MetadataStore(path: path)
    store.update(chatId: 42, name: "Alice", memberCount: 2, chatType: 0, messageCount: 7)
    store.setInTopLevelList(chatId: 42, true)
    store.setInTopLevelList(chatId: 99, false, name: "Hidden Group")
    try store.save()

    let reloaded = MetadataStore(path: path)
    #expect(reloaded.count == 2, "a store that can't read itself back is write-only")
    #expect(reloaded.name(for: 42) == "Alice")
    #expect(reloaded.info(for: 42)?.messageCount == 7)
    #expect(reloaded.info(for: 42)?.lastHarvested != nil, "dates must survive the round trip")
    #expect(reloaded.info(for: 42)?.inTopLevelList == true)
    #expect(reloaded.info(for: 99)?.inTopLevelList == false)

    let unreachable = reloaded.unreachableChats
    #expect(unreachable.count == 1)
    #expect(unreachable.first?.id == 99)
    #expect(unreachable.first?.name == "Hidden Group")
}

@Test func neverHarvestedChatsAreUnknownNotReachable() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("kakaocli-metadata-test-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let store = MetadataStore(path: path)
    store.update(chatId: 1, name: "Alice")
    try store.save()

    // nil, not false: absence of a harvest is not evidence a chat is reachable,
    // and it must not be reported as unreachable either.
    #expect(MetadataStore(path: path).info(for: 1)?.inTopLevelList == nil)
    #expect(MetadataStore(path: path).unreachableChats.isEmpty)
}
