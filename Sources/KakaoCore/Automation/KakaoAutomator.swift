import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        let debug = ProcessInfo.processInfo.environment["KAKAOCLI_DEBUG"] != nil
        func dlog(_ s: String) { if debug { fputs("[send] \(s)\n", stderr) } }

        dlog("step1 ensureReady begin")
        // 1. Ensure KakaoTalk is running and logged in
        let stateBefore = AppLifecycle.detectState()
        dlog("step1 stateBefore=\(stateBefore)")
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if stateBefore != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }
        dlog("step1 done")

        // 2. Activate KakaoTalk and get windows
        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)

        let windows = AXHelpers.windows(app)
        dlog("step2 windows.count=\(windows.count)")
        for (i, w) in windows.enumerated() {
            dlog("  window[\(i)] role=\(AXHelpers.role(w) ?? "?") id=\(AXHelpers.identifier(w) ?? "?") title=\(AXHelpers.title(w) ?? "?")")
        }
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            dlog("step2 FAIL: no 'Main Window' identifier found")
            throw AutomationError.noWindows
        }
        dlog("step2 mainWindow found")

        // 3. Close any existing chat windows to avoid sending to the wrong one
        for w in windows where AXHelpers.identifier(w) != "Main Window" {
            _ = AXHelpers.closeWindow(w)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }
        dlog("step3 closed non-main windows")

        // 4. Ensure we're on the Chats tab.
        // The sidebar tabs are direct children of the main window (AXButton id="chatrooms"
        // in current KakaoTalk Mac; older builds exposed it as AXCheckBox). Cap search depth
        // so this stays cheap even when the chat list subtree is huge under
        // AXManualAccessibility.
        let chatroomsTab =
            AXHelpers.findFirst(mainWindow, role: "AXButton", identifier: "chatrooms", maxDepth: 3) ??
            AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms", maxDepth: 3)
        if let chatroomsTab {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }
        dlog("step4 chats tab ensured (found=\(chatroomsTab != nil))")

        // 5. Find the chat row in the list
        guard let table = AXHelpers.chatListTable(mainWindow) else {
            dlog("step5 FAIL: chatListTable(mainWindow) returned nil")
            throw AutomationError.chatNotFound(chatName)
        }
        dlog("step5 chat list table found, searching row selfChat=\(selfChat)")

        let row: AXUIElement
        if selfChat {
            guard let selfRow = AXHelpers.findSelfChatRow(table) else {
                dlog("step5 FAIL: findSelfChatRow nil")
                throw AutomationError.chatNotFound("self-chat (나와의 채팅)")
            }
            row = selfRow
        } else {
            guard let chatRow = AXHelpers.findChatRow(table, chatName: chatName) else {
                dlog("step5 FAIL: findChatRow(\(chatName)) nil")
                throw AutomationError.chatNotFound(chatName)
            }
            row = chatRow
        }
        dlog("step5 row found")

        // 6. Open the chat via AX row selection + Enter (works even when off-screen).
        //    Falls back to scroll-into-view + double-click if selection fails.
        var opened = false
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            Thread.sleep(forTimeInterval: 0.5)
            let checkWindows = AXHelpers.windows(app)
            opened = checkWindows.contains { AXHelpers.identifier($0) != "Main Window" }
            dlog("step6 selectRow+Enter opened=\(opened)")
        }
        if !opened {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
            dlog("step6 fallback double-click")
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
            dlog("step7 FAIL: chat window did not appear within 5s")
            throw AutomationError.inputFieldNotFound
        }
        dlog("step7 chatWindow role=\(AXHelpers.role(chatWindow) ?? "?") title=\(AXHelpers.title(chatWindow) ?? "?")")

        // 8. Find the message input field
        // Dump children for debug
        if debug {
            let kids = AXHelpers.children(chatWindow)
            dlog("step8 chatWindow.children.count=\(kids.count)")
            for (i, k) in kids.enumerated() {
                let rl = AXHelpers.role(k) ?? "?"
                let ds = AXHelpers.description(k) ?? ""
                dlog("  child[\(i)] role=\(rl) desc=\(ds)")
                if rl == "AXScrollArea" {
                    let subs = AXHelpers.children(k)
                    for (j, s) in subs.enumerated() {
                        dlog("    scroll_child[\(j)] role=\(AXHelpers.role(s) ?? "?") desc=\(AXHelpers.description(s) ?? "")")
                    }
                }
            }
        }
        guard let inputField = findInputField(in: chatWindow) else {
            dlog("step8 FAIL: findInputField returned nil")
            throw AutomationError.inputFieldNotFound
        }
        dlog("step8 inputField found role=\(AXHelpers.role(inputField) ?? "?") desc=\(AXHelpers.description(inputField) ?? "")")

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

    /// Find the message input AXTextArea in a chat window.
    /// The input is in a top-level AXScrollArea that does NOT contain an AXTable (messages).
    private func findInputField(in window: AXUIElement) -> AXUIElement? {
        for child in AXHelpers.children(window) {
            guard AXHelpers.role(child) == "AXScrollArea" else { continue }
            // The message list scroll area contains an AXTable; the input one doesn't
            let hasTable = AXHelpers.children(child).contains { AXHelpers.role($0) == "AXTable" }
            if !hasTable {
                // This scroll area should contain the input AXTextArea
                for subchild in AXHelpers.children(child) {
                    if AXHelpers.role(subchild) == "AXTextArea" {
                        return subchild
                    }
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
            return """
            Could not find the message input field.

            Recent KakaoTalk Mac builds (v26.x+) do not expose their AX hierarchy by \
            default. To enable it, run:

              defaults write com.kakao.KakaoTalkMac AXManualAccessibility -bool true
              osascript -e 'quit app "KakaoTalk"' && sleep 2 && open -a KakaoTalk

            After re-logging in, retry. Re-run with KAKAOCLI_DEBUG=1 for verbose traces.
            """
        case .sendFailed(let msg):
            return "Failed to send message: \(msg)"
        }
    }
}
