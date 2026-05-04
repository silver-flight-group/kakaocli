import AppKit
import ApplicationServices
import Foundation

/// Automates KakaoTalk UI for sending messages.
public final class KakaoAutomator {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Send a message to a chat by navigating the UI.
    public func sendMessage(to chatName: String, message: String, selfChat: Bool = false) throws {
        let session = try openConversation(to: chatName, selfChat: selfChat)

        // Wait briefly for the message composer to become available.
        let inputDeadline = Date().addingTimeInterval(10.0)
        var activeContainer = session.conversationContainer
        var inputField: AXUIElement?
        while Date() < inputDeadline {
            inputField = AXHelpers.findMessageComposer(in: activeContainer)
            if inputField == nil, AXHelpers.identifier(activeContainer) != "Main Window",
               let inlineInput = AXHelpers.findMessageComposer(in: session.mainWindow) {
                activeContainer = session.mainWindow
                inputField = inlineInput
            }
            if inputField != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let inputField else {
            throw AutomationError.inputFieldNotFound
        }

        // Focus and type the message.
        _ = AXHelpers.performAction(activeContainer, kAXRaiseAction as String)
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

        Thread.sleep(forTimeInterval: 0.3)
        if AXHelpers.identifier(activeContainer) != "Main Window" {
            _ = AXHelpers.closeWindow(activeContainer)
        }
    }

    /// Leave a group chat through KakaoTalk's chat window menu.
    public func leaveChat(to chatName: String) throws {
        let session = try openConversation(to: chatName, selfChat: false, exactChatName: true)
        _ = AXHelpers.performAction(session.conversationContainer, kAXRaiseAction as String)
        Thread.sleep(forTimeInterval: 0.3)

        guard let menuButton = findConversationMenuButton(in: session.conversationContainer) else {
            throw AutomationError.menuButtonNotFound(chatName)
        }

        if !AXHelpers.performAction(menuButton, kAXPressAction as String) {
            AXHelpers.clickElement(menuButton)
        }
        Thread.sleep(forTimeInterval: 0.4)

        guard let leaveItem = waitForMenuItem(
            in: session.app,
            labels: ["Leave chatroom", "Leave Chatroom", "Leave Chat", "채팅방 나가기", "나가기"],
            timeout: 3.0
        ) else {
            throw AutomationError.leaveMenuItemNotFound(chatName)
        }
        if !AXHelpers.performAction(leaveItem, kAXPressAction as String) {
            AXHelpers.clickElement(leaveItem)
        }

        if let confirmButton = waitForConfirmationButton(
            in: session.app,
            includeLabels: ["Leave", "Leave chatroom", "Leave Chatroom", "Leave Chat Room", "OK", "확인", "나가기"],
            excludeLabels: ["Cancel", "취소", "No", "아니오"],
            timeout: 5.0
        ) {
            if !AXHelpers.performAction(confirmButton, kAXPressAction as String) {
                AXHelpers.clickElement(confirmButton)
            }
        } else if hasConfirmationPrompt(in: session.app) {
            throw AutomationError.leaveConfirmationButtonNotFound(chatName)
        }
    }

    private struct ConversationSession {
        let app: AXUIElement
        let mainWindow: AXUIElement
        let conversationContainer: AXUIElement
    }

    private func openConversation(
        to chatName: String,
        selfChat: Bool,
        exactChatName: Bool = false
    ) throws -> ConversationSession {
        let stateBefore = AppLifecycle.detectState()
        try AppLifecycle.ensureReady(credentials: CredentialStore())
        if stateBefore != .loggedIn {
            Thread.sleep(forTimeInterval: 2.0)
        }

        try AXHelpers.activateApp(bundleId: Self.bundleId)
        let app = try AXHelpers.appElement(bundleId: Self.bundleId)

        let windows = AXHelpers.windows(app)
        guard let mainWindow = windows.first(where: { AXHelpers.identifier($0) == "Main Window" }) else {
            throw AutomationError.noWindows
        }

        // Close existing chat windows so the next action cannot target an old conversation.
        for window in windows where AXHelpers.identifier(window) != "Main Window" {
            _ = AXHelpers.closeWindow(window)
        }
        if windows.count > 1 {
            Thread.sleep(forTimeInterval: 0.3)
        }

        let chatroomsTab =
            AXHelpers.findFirst(mainWindow, role: "AXCheckBox", identifier: "chatrooms") ??
            AXHelpers.findFirst(mainWindow, role: "AXButton", identifier: "chatrooms")
        if let chatroomsTab {
            _ = AXHelpers.performAction(chatroomsTab, kAXPressAction as String)
            Thread.sleep(forTimeInterval: 0.3)
        }

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
            let chatRows = AXHelpers.findChatRows(table, chatName: chatName, exact: exactChatName)
            guard !chatRows.isEmpty, let chatRow = chatRows.first else {
                throw AutomationError.chatNotFound(chatName)
            }
            if exactChatName && chatRows.count > 1 {
                throw AutomationError.ambiguousChatName(chatName, chatRows.count)
            }
            row = chatRow
        }

        func waitForConversationContainer(timeout: TimeInterval = 2.0) -> AXUIElement? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                let updatedWindows = AXHelpers.windows(app)
                if let chatWindow = updatedWindows.first(where: { AXHelpers.identifier($0) != "Main Window" }) {
                    return chatWindow
                }
                if AXHelpers.findMessageComposer(in: mainWindow) != nil {
                    return mainWindow
                }
            }
            return nil
        }

        var conversationContainer: AXUIElement?
        if AXHelpers.selectRow(row, in: table) {
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36) // Enter to open
            conversationContainer = waitForConversationContainer()
        }
        if conversationContainer == nil {
            AXHelpers.clickElement(row)
            Thread.sleep(forTimeInterval: 0.2)
            AXHelpers.pressKey(keyCode: 36)
            conversationContainer = waitForConversationContainer()
        }
        if conversationContainer == nil,
           let nameLabel = AXHelpers.findFirst(row, role: "AXStaticText", text: chatName, maxDepth: 4) {
            AXHelpers.doubleClickElement(nameLabel)
            conversationContainer = waitForConversationContainer()
        }
        if conversationContainer == nil,
           let cell = AXHelpers.children(row).first(where: { AXHelpers.role($0) == "AXCell" }) {
            AXHelpers.doubleClickElement(cell)
            conversationContainer = waitForConversationContainer()
        }
        if conversationContainer == nil {
            if let scrollArea = AXHelpers.chatListScrollArea(mainWindow) {
                _ = AXHelpers.scrollRowToVisible(row, in: scrollArea)
                Thread.sleep(forTimeInterval: 0.3)
            }
            AXHelpers.doubleClickElement(row)
            conversationContainer = waitForConversationContainer(timeout: 5.0)
        }

        guard let conversationContainer else {
            throw AutomationError.inputFieldNotFound
        }
        return ConversationSession(
            app: app,
            mainWindow: mainWindow,
            conversationContainer: conversationContainer
        )
    }

    private func findConversationMenuButton(in container: AXUIElement) -> AXUIElement? {
        AXHelpers.findAll(container, role: "AXButton", maxDepth: 12).first { element in
            labelMatches(element, include: ["Menu", "메뉴"])
        }
    }

    private func waitForMenuItem(
        in app: AXUIElement,
        labels: [String],
        timeout: TimeInterval
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for root in searchRoots(for: app) {
                if let item = AXHelpers.findAll(root, role: "AXMenuItem", maxDepth: 14).first(where: {
                    labelMatches($0, include: labels)
                }) {
                    return item
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func waitForConfirmationButton(
        in app: AXUIElement,
        includeLabels: [String],
        excludeLabels: [String],
        timeout: TimeInterval
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for root in searchRoots(for: app) {
                if let button = AXHelpers.findAll(root, role: "AXButton", maxDepth: 14).first(where: {
                    labelMatches($0, include: includeLabels, exclude: excludeLabels)
                }) {
                    return button
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func hasConfirmationPrompt(in app: AXUIElement) -> Bool {
        searchRoots(for: app).contains { root in
            AXHelpers.findAll(root, role: "AXButton", maxDepth: 14).contains {
                labelMatches($0, include: ["Cancel", "취소", "No", "아니오"])
            }
        }
    }

    private func searchRoots(for app: AXUIElement) -> [AXUIElement] {
        [app] + AXHelpers.windows(app)
    }

    private func labelMatches(
        _ element: AXUIElement,
        include: [String],
        exclude: [String] = []
    ) -> Bool {
        let labels = [
            AXHelpers.title(element),
            AXHelpers.value(element),
            AXHelpers.description(element),
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        guard labels.contains(where: { label in
            include.contains(where: { label.localizedCaseInsensitiveContains($0) })
        }) else {
            return false
        }
        return !labels.contains(where: { label in
            exclude.contains(where: { label.localizedCaseInsensitiveContains($0) })
        })
    }
}

public enum AutomationError: Error, CustomStringConvertible {
    case noWindows
    case chatNotFound(String)
    case inputFieldNotFound
    case sendFailed(String)
    case ambiguousChatName(String, Int)
    case menuButtonNotFound(String)
    case leaveMenuItemNotFound(String)
    case leaveConfirmationButtonNotFound(String)

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
        case .ambiguousChatName(let name, let count):
            return "Chat '\(name)' matched \(count) rows; refusing to continue"
        case .menuButtonNotFound(let name):
            return "Could not find the chat menu button for '\(name)'"
        case .leaveMenuItemNotFound(let name):
            return "Could not find the leave-chatroom menu item for '\(name)'"
        case .leaveConfirmationButtonNotFound(let name):
            return "Could not find the leave confirmation button for '\(name)'"
        }
    }
}
