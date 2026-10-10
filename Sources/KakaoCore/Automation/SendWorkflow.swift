import Foundation

/// The send workflow is independent of AX so safety failures can be tested without
/// launching KakaoTalk, accessing credentials, or generating keyboard events.
struct SendWindow<Element> {
    let element: Element
    let identifier: String?
    let title: String?
    let isWindow: Bool
}

struct SendChatRow<Element> {
    let element: Element
    let name: String?
    let isSelfChat: Bool
}

protocol SendUI {
    associatedtype Element

    func prepare() throws
    func windows() -> [SendWindow<Element>]
    func sameElement(_ lhs: Element, _ rhs: Element) -> Bool
    func closeWindow(_ window: Element) -> Bool
    func chatRows(in mainWindow: Element) throws -> [SendChatRow<Element>]
    func openChat(_ row: Element, in mainWindow: Element) throws
    func inputField(in window: Element) -> Element?
    func focusInput(_ input: Element, in window: Element) throws
    func isFocused(_ input: Element, in window: Element) -> Bool
    func setMessage(_ message: String, in input: Element) -> Bool
    func messageValue(in input: Element) -> String?
    func submitMessage(_ message: String, in input: Element, window: Element, main: Element, title: String) throws
    func wait(_ interval: TimeInterval)
}

struct SendWorkflow<UI: SendUI> {
    let ui: UI

    func send(to chatName: String, message: String, selfChat: Bool) throws {
        guard selfChat || !chatName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError.chatNotFound(chatName)
        }
        try ui.prepare()
        let initialWindows = ui.windows()
        let mains = initialWindows.filter { $0.identifier == "Main Window" && $0.isWindow }
        guard mains.count == 1, let main = mains.first else {
            throw AutomationError.noWindows
        }
        guard initialWindows.allSatisfy({ $0.isWindow }) else {
            throw AutomationError.sendFailed("Could not identify all open windows")
        }

        // A failed close must never leave a stale chat eligible for selection.
        for window in initialWindows where !ui.sameElement(window.element, main.element) {
            guard ui.closeWindow(window.element) else {
                throw AutomationError.sendFailed("Could not close an existing window")
            }
        }
        if initialWindows.count > 1 { ui.wait(0.3) }
        let baseline = ui.windows()
        guard baseline.count == 1, let remaining = baseline.first,
              remaining.isWindow, remaining.identifier == "Main Window",
              ui.sameElement(remaining.element, main.element) else {
            throw AutomationError.sendFailed("An existing window is still open")
        }

        let rows = try ui.chatRows(in: main.element)
        guard rows.allSatisfy({ $0.name.map { !$0.isEmpty } ?? false }) else {
            throw AutomationError.sendFailed("Could not verify all chat names for unique targeting")
        }
        let matches = rows.filter {
            selfChat ? $0.isSelfChat : $0.name == chatName
        }
        let targetDescription = selfChat ? "self-chat (나와의 채팅)" : chatName
        guard !matches.isEmpty else { throw AutomationError.chatNotFound(targetDescription) }
        guard matches.count == 1, let row = matches.first else {
            throw AutomationError.ambiguousChat(targetDescription)
        }
        guard let expectedTitle = row.name, !expectedTitle.isEmpty else {
            throw AutomationError.sendFailed("Could not verify the selected chat name")
        }

        try ui.openChat(row.element, in: main.element)
        var target: SendWindow<UI.Element>?
        for _ in 0..<10 {
            ui.wait(0.5)
            if let window = try verifiedChatWindow(main: main.element, title: expectedTitle) {
                target = window
                break
            }
        }
        guard let target else {
            throw AutomationError.sendFailed("The selected chat window did not open")
        }
        guard let input = ui.inputField(in: target.element) else {
            throw AutomationError.inputFieldNotFound
        }

        try ui.focusInput(input, in: target.element)
        try verifyTarget(target.element, main: main.element, title: expectedTitle, input: input)
        guard ui.setMessage(message, in: input), ui.messageValue(in: input) == message else {
            // Global typing is unsafe when AX cannot address the verified field.
            throw AutomationError.sendFailed("Could not set and verify the message input")
        }
        ui.wait(0.2)
        try verifyTarget(target.element, main: main.element, title: expectedTitle, input: input)
        guard ui.messageValue(in: input) == message else {
            throw AutomationError.sendFailed("The message input changed before send")
        }
        try ui.submitMessage(message, in: input, window: target.element, main: main.element, title: expectedTitle)
        ui.wait(0.3)
        _ = ui.closeWindow(target.element)
    }

    private func verifiedChatWindow(main: UI.Element, title: String) throws -> SendWindow<UI.Element>? {
        let windows = ui.windows()
        let mains = windows.filter { $0.identifier == "Main Window" }
        guard mains.count == 1, let currentMain = mains.first, currentMain.isWindow,
              ui.sameElement(currentMain.element, main), windows.allSatisfy({ $0.isWindow }) else {
            throw AutomationError.sendFailed("The main window changed during send")
        }
        let chats = windows.filter { !ui.sameElement($0.element, main) }
        if chats.isEmpty { return nil }
        guard chats.count == 1, let chat = chats.first, chat.title == title else {
            throw AutomationError.sendFailed("The opened window does not uniquely match the selected chat")
        }
        return chat
    }

    private func verifyTarget(_ target: UI.Element, main: UI.Element, title: String,
                              input: UI.Element) throws {
        guard let current = try verifiedChatWindow(main: main, title: title),
              ui.sameElement(current.element, target),
              let currentInput = ui.inputField(in: target), ui.sameElement(currentInput, input),
              ui.isFocused(input, in: target) else {
            throw AutomationError.sendFailed("The chat window or input focus changed during send")
        }
    }
}
