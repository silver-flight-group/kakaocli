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

    func run() throws {
        let bundleId = "com.kakao.KakaoTalkMac"
        try AXHelpers.activateApp(bundleId: bundleId)

        let app = try AXHelpers.appElement(bundleId: bundleId)
        let windows = AXHelpers.windows(app)

        if windows.isEmpty {
            print("No windows found. Is KakaoTalk running?")
            throw ExitCode.failure
        }

        if let chatName = openChat {
            // Click on a chat to open it, then inspect the resulting windows
            guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
                print("Could not find main window")
                throw ExitCode.failure
            }
            let chatroomsTab =
                AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") ??
                AXHelpers.findFirst(mainWindow, role: "AXButton", identifier: "chatrooms")
            if let chatroomsTab {
                _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
                Thread.sleep(forTimeInterval: 0.3)
            }
            if let table = AXHelpers.chatListTable(mainWindow) {
                if let row = AXHelpers.findChatRow(table, chatName: chatName) {
                    print("Found chat: \(chatName), double-clicking to open...")
                    AXHelpers.doubleClickElement(row)
                    Thread.sleep(forTimeInterval: 1.0)
                } else {
                    print("Chat '\(chatName)' not found in chat list")
                    throw ExitCode.failure
                }
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
