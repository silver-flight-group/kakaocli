import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        // 1. Ensure KakaoTalk is running and logged in
        let stateBefore = AppLifecycle.detectState()
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if stateBefore != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }

        // 2. Activate KakaoTalk and get windows
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)

        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // 3. Close any existing chat windows to avoid sending to the wrong one
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 4. Ensure we're on the Chats tab
        let chatroomsTab =
            AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") ??
            AXHelpers.findFirst(mainWindow, role: "AXButton", identifier: "chatrooms")
        if let chatroomsTab {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 5. Find the chat row in the list
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            throw AutomationError.chatNotFound(chatName)
        }

        let row: AXUIElement
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
        } else {
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName) else {
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
        }

        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            Thread.sleep(forTimeInterval: 0.5)
            let checkWindows = AXHelpers.windows(app)
            opened = checkWindows.contains { AXHelpers.identifier($0) != "Main Window" }
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
        }

        // 7. Wait for the chat window to appear
        var chatWindow: AXUIElement?
        let windowDeadline = Date().addingTimeInterval(5.0)
        while Date() < windowDeadline {
            Thread.sleep(forTimeInterval: 0.5)
            let updatedWindows = AXHelpers.windows(app)
            chatWindow = updatedWindows.first(where: { AXHelpers.identifier($0) != "Main Window" })
            if chatWindow != nil { break }
        }
        guard let chatWindow else {
            throw AutomationError.inputFieldNotFound
        }

        // 8. Wait briefly for the message composer to become available.
        let inputDeadline = Date().addingTimeInterval(5.0)
        var inputField: AXUIElement?
        while Date() < inputDeadline {
            inputField = findInputField(in: chatWindow)
            if inputField != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let inputField else {
            throw AutomationError.inputFieldNotFound
        }

        // 9. Focus and type the message
        _ = AXHelpers.performAction(chatWindow, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)
        AXHelpers.clickElement(inputField)
        Thread.sleep(forTimeInterval: 0.3)

        if AXHelpers.setValue(inputField, message) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        } else {
            _ = AXHelpers.focus(inputField)
            Thread.sleep(forTimeInterval: 0.1)
            AXHelpers.typeText(message)
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Return key
        }

        // 10. Close the chat window
        Thread.sleep(forTimeInterval: 0.3)
        _ = AXHelpers.closeWindow(chatWindow)
    }

    /// Find the message composer in a chat window.
    /// The composer lives inside a top-level AXScrollArea that does not contain the
    /// message AXTable. Some KakaoTalk builds wrap the editable field deeper than one level.
    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        for child in AXHelpers.children(window) {
            guard AXHelpers.role(child) == "AXScrollArea" else { continue }
            // The message list scroll area contains an AXTable; the composer one doesn't.
            let hasTable = AXHelpers.children(child).contains { AXHelpers.role($0) == "AXTable" }
            if !hasTable {
                let textAreas = AXHelpers.findAll(child, role: "AXTextArea", maxDepth: 4)
                if let composer = textAreas.first(where: {
                    let desc = AXHelpers.description($0) ?? ""
                    return desc.localizedCaseInsensitiveContains("enter a message")
                }) {
                    return composer
                }
                if let composer = textAreas.first {
                    return composer
                }

                let textFields = AXHelpers.findAll(child, role: "AXTextField", maxDepth: 4)
                if let composer = textFields.first(where: {
                    let desc = AXHelpers.description($0) ?? ""
                    return desc.localizedCaseInsensitiveContains("enter a message")
                }) {
                    return composer
                }
                if let composer = textFields.first {
                    return composer
                }
            }
        }
        return nil
    }

}

public enum AutomationError: Error, CustomStringConvertible {
    case noWindows
    case chatNotFound(String)
    case inputFieldNotFound
    case sendFailed(String)

    public var description: String {
        switch self {
        case .noWindows:
            return "KakaoTalk has no open windows"
        case .chatNotFound(let name):
            return "Chat '\(name)' not found in the chat list"
        case .inputFieldNotFound:
            return "Could not find the message input field"
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
