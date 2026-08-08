import ApplicationServices
import ArgumentParser
import Foundation
import KakaoCore

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Dump KakaoTalk UI element tree (for debugging automation)"
    )

    @Option(name: .long, help: "Max tree depth to inspect")
    var depth: Int = 5

    @Option(name: .long, help: "Open a chat by name and inspect the chat window")
    var openChat: String?

    @Option(name: .long, help: "Type a term into KakaoTalk's chat search and inspect the result")
    var search: String?

    @Flag(name: .long, help: "Dismiss any active chat search and restore the full list")
    var clearSearch = false

    func run() throws {
        let bundleId = "com.kakao.KakaoTalkMac"
        try AXHelpers.activateApp(bundleId: bundleId)

        let app = try AXHelpers.appElement(bundleId: bundleId)
        let windows = AXHelpers.windows(app)

        if windows.isEmpty {
            print("No windows found. Is KakaoTalk running?")
            throw ExitCode.failure
        }

        if clearSearch {
            guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
                print("Could not find main window")
                throw ExitCode.failure
            }
            let ok = AXHelpers.clearChatSearch(in: mainWindow)
            let rows = AXHelpers.chatListTable(mainWindow).map { AXHelpers.children($0).filter { AXHelpers.role($0) == "AXRow" }.count } ?? 0
            print(ok ? "Search cleared — \(rows) chats listed" : "Could NOT clear the search — \(rows) chats listed")
            return
        }

        if let term = search {
            // Press KakaoTalk's own chat search and type a term, then dump the
            // result. Exists to work out how to reach chats that have no row in
            // the top-level list because a folder ("Silent Chatroom") holds them.
            guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
                print("Could not find main window")
                throw ExitCode.failure
            }
            if let tab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
                _ = AXHelpers.performAction(tab, kAXPressAction as String)
                Thread.sleep(forTimeInterval: 0.3)
            }
            guard let searchButton = AXHelpers.findFirst(mainWindow, role: "AXButton", description: "Search") else {
                print("No Search button found in the main window")
                throw ExitCode.failure
            }
            _ = AXHelpers.performAction(searchButton, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.8)
            let fields = AXHelpers.findAll(mainWindow, role: "AXTextField")
                + AXHelpers.findAll(mainWindow, role: "AXSearchField")
            print("search fields found: \(fields.count)")
            if let field = fields.first {
                _ = AXHelpers.focus(field)
                Thread.sleep(forTimeInterval: 0.2)
                if !AXHelpers.setValue(field, term) {
                    AXHelpers.typeText(term)
                }
                Thread.sleep(forTimeInterval: 1.2)
            } else {
                AXHelpers.typeText(term)
                Thread.sleep(forTimeInterval: 1.2)
            }
            for (i, window) in AXHelpers.windows(app).enumerated() {
                print("=== Window \(i): \(AXHelpers.title(window) ?? "(untitled)") ===")
                print(AXHelpers.dumpTree(window, maxDepth: depth))
            }
            // Restore the list. Leaving the filter applied strands the user on a
            // one-row chat list, and makes the next lookup look like it found a
            // chat in the top-level list when it only found the filtered result.
            AXHelpers.clearChatSearch(in: mainWindow)
            return
        }

        if let chatName = openChat {
            // Click on a chat to open it, then inspect the resulting windows
            guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
                print("Could not find main window")
                throw ExitCode.failure
            }
            if let chatroomsTab = AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") {
                _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
                Thread.sleep(forTimeInterval: 0.3)
            }
            if let table0 = AXHelpers.chatListTable(mainWindow) {
                AXHelpers.clearChatSearch(in: mainWindow)
                let table = AXHelpers.chatListTable(mainWindow) ?? table0
                var row = AXHelpers.findChatRow(table, chatName: chatName)
                var viaSearch = false
                if row == nil {
                    // Same fallback the send path uses: a folder hides the chat
                    // from the top-level list but KakaoTalk still finds it.
                    row = AXHelpers.searchChatRow(in: mainWindow, chatName: chatName)
                    viaSearch = row != nil
                }
                guard let row else {
                    AXHelpers.clearChatSearch(in: mainWindow)
                    print("Chat '\(chatName)' not found in chat list or search")
                    throw ExitCode.failure
                }
                print("Found chat: \(chatName)\(viaSearch ? " (via search — it is inside a folder)" : ""), opening...")
                // Select + Enter rather than a double-click: activation is
                // positional and the list re-sorts whenever a message arrives,
                // so the second click of a double-click can land on a different
                // chat than the one matched.
                let active = AXHelpers.chatListTable(mainWindow) ?? table
                var opened = false
                if AXHelpers.selectRow(row, in: active) {
                    Thread.sleep(forTimeInterval: 0.2)
                    AXHelpers.pressKey(keyCode: 36)
                    Thread.sleep(forTimeInterval: 0.6)
                    opened = AXHelpers.windows(app).contains { AXHelpers.identifier($0) != "Main Window" }
                }
                if !opened {
                    // Enter does nothing while focus sits in the search field,
                    // which is exactly where it is after a search.
                    AXHelpers.doubleClickElement(row)
                    Thread.sleep(forTimeInterval: 1.0)
                }
                if viaSearch { AXHelpers.clearChatSearch(in: mainWindow) }
            }
            // Re-fetch windows after opening chat
            let updatedWindows = AXHelpers.windows(app)
            for (i, window) in updatedWindows.enumerated() {
                let title = AXHelpers.title(window) ?? "(untitled)"
                print("=== Window \(i): \(title) ===")
                print(AXHelpers.dumpTree(window, maxDepth: depth))
            }
        } else {
            for (i, window) in windows.enumerated() {
                let title = AXHelpers.title(window) ?? "(untitled)"
                print("=== Window \(i): \(title) ===")
                print(AXHelpers.dumpTree(window, maxDepth: depth))
            }
        }
    }
}
