import Foundation
import Testing
@testable import KakaoCore

private final class FakeSendUI: SendUI {
    typealias Element = String

    static func window(_ id: String, title: String? = nil, isWindow: Bool = true) -> SendWindow<String> {
        SendWindow(element: id, identifier: id == "main" ? "Main Window" : nil,
                   title: title, isWindow: isWindow)
    }

    var currentWindows = [window("main")]
    var rows = [SendChatRow(element: "alice-row", name: "Alice", isSelfChat: false)]
    var openedWindows = [window("main"), window("alice-window", title: "Alice")]
    var closeSucceeds = true
    var closeRemovesWindow = true
    var focused = true
    var inputAvailable = true
    var setSucceeds = true
    var storedMessage: String?
    var openedRows: [String] = []
    var writes: [String] = []
    var returnCount = 0
    var beforeSubmit: (() -> Void)?
    var afterSet: (() -> Void)?
    var afterWriteWait: (() -> Void)?

    func prepare() throws {}
    func windows() -> [SendWindow<String>] { currentWindows }
    func sameElement(_ lhs: String, _ rhs: String) -> Bool { lhs == rhs }
    func wait(_ interval: TimeInterval) {
        if !writes.isEmpty { afterWriteWait?() }
    }
    func closeWindow(_ window: String) -> Bool {
        if closeSucceeds && closeRemovesWindow { currentWindows.removeAll { $0.element == window } }
        return closeSucceeds
    }
    func chatRows(in mainWindow: String) throws -> [SendChatRow<String>] { rows }
    func openChat(_ row: String, in mainWindow: String) throws {
        openedRows.append(row)
        currentWindows = openedWindows
    }
    func inputField(in window: String) -> String? { inputAvailable ? window + "-input" : nil }
    func focusInput(_ input: String, in window: String) throws {}
    func isFocused(_ input: String, in window: String) -> Bool { focused }
    func setMessage(_ message: String, in input: String) -> Bool {
        writes.append(input)
        if setSucceeds { storedMessage = message }
        afterSet?()
        return setSucceeds
    }
    func messageValue(in input: String) -> String? { storedMessage }
    func submitMessage(_ message: String, in input: String, window: String, main: String, title: String) throws {
        beforeSubmit?()
        guard currentWindows.count == 2,
              currentWindows.contains(where: { $0.element == main && $0.identifier == "Main Window" }),
              currentWindows.contains(where: { $0.element == window && $0.title == title }),
              messageValue(in: input) == message, isFocused(input, in: window) else {
            throw AutomationError.sendFailed("Target changed at submission")
        }
        returnCount += 1
    }
}

@Test func sendRequiresAnExactName() {
    let ui = FakeSendUI()
    ui.rows = [SendChatRow(element: "other-row", name: "Alice's team", isSelfChat: false)]
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.openedRows.isEmpty)
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendRejectsDuplicateExactNames() {
    let ui = FakeSendUI()
    ui.rows.append(SendChatRow(element: "second-alice", name: "Alice", isSelfChat: false))
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.openedRows.isEmpty)
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendSelectsExactNameInsteadOfEarlierSubstring() throws {
    let ui = FakeSendUI()
    ui.rows.insert(SendChatRow(element: "other-row", name: "Alice's team", isSelfChat: false), at: 0)
    try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    #expect(ui.openedRows == ["alice-row"])
    #expect(ui.writes == ["alice-window-input"])
    #expect(ui.returnCount == 1)
}

@Test(arguments: [false, true]) func sendRejectsFailedOrIneffectiveWindowClose(reportedSuccess: Bool) {
    let ui = FakeSendUI()
    ui.currentWindows.append(FakeSendUI.window("stale", title: "Alice"))
    ui.closeSucceeds = reportedSuccess
    ui.closeRemovesWindow = false
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.openedRows.isEmpty)
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test(arguments: ["Bob", "", "Alice's team"])
func sendRejectsAnUnexpectedWindowTitle(title: String) {
    let ui = FakeSendUI()
    ui.openedWindows = [FakeSendUI.window("main"), FakeSendUI.window("other", title: title)]
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendRejectsAnExtraWindowEvenWithOneMatchingTitle() {
    let ui = FakeSendUI()
    ui.openedWindows.append(FakeSendUI.window("popup", title: "Settings"))
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendRejectsNonWindowAXElements() {
    let ui = FakeSendUI()
    ui.openedWindows = [FakeSendUI.window("main"), FakeSendUI.window("app", title: "Alice", isWindow: false)]
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendTimesOutWithoutTyping() {
    let ui = FakeSendUI()
    ui.openedWindows = [FakeSendUI.window("main")]
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendRequiresVerifiedFocusBeforeTyping() {
    let ui = FakeSendUI()
    ui.focused = false
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test(arguments: ["focus", "window", "title", "value"])
func sendRevalidatesImmediatelyBeforeReturn(change: String) {
    let ui = FakeSendUI()
    ui.afterSet = { [unowned ui] in
        switch change {
        case "focus": ui.focused = false
        case "window":
            ui.currentWindows = [FakeSendUI.window("main"), FakeSendUI.window("replacement", title: "Alice")]
        case "title":
            ui.currentWindows = [FakeSendUI.window("main"), FakeSendUI.window("alice-window", title: "Bob")]
        default: ui.storedMessage = "unexpected content"
        }
    }
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.count == 1)
    #expect(ui.returnCount == 0)
}

@Test func sendNeverFallsBackToGlobalTypingAfterAXWriteFailure() {
    let ui = FakeSendUI()
    ui.setSucceeds = false
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.count == 1)
    #expect(ui.returnCount == 0)
}

@Test func selfChatUsesUniqueBadgeAndVerifiesItsWindow() throws {
    let ui = FakeSendUI()
    ui.rows = [SendChatRow(element: "me-row", name: "Me", isSelfChat: true)]
    ui.openedWindows = [FakeSendUI.window("main"), FakeSendUI.window("me-window", title: "Me")]
    try SendWorkflow(ui: ui).send(to: "ignored", message: "hello", selfChat: true)
    #expect(ui.openedRows == ["me-row"])
    #expect(ui.writes == ["me-window-input"])
    #expect(ui.returnCount == 1)
}

@Test func selfChatRejectsDuplicateBadges() {
    let ui = FakeSendUI()
    ui.rows = [SendChatRow(element: "one", name: "Me", isSelfChat: true),
               SendChatRow(element: "two", name: "Me too", isSelfChat: true)]
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "ignored", message: "hello", selfChat: true)
    }
    #expect(ui.openedRows.isEmpty)
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendRechecksMessageAfterSettling() {
    let ui = FakeSendUI()
    ui.afterWriteWait = { [unowned ui] in ui.storedMessage = "changed during wait" }
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.returnCount == 0)
}

@Test func sendRejectsMissingInputWithoutTyping() {
    let ui = FakeSendUI()
    ui.inputAvailable = false
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test func sendRejectsMissingWindowTitle() {
    let ui = FakeSendUI()
    ui.openedWindows = [FakeSendUI.window("main"), FakeSendUI.window("alice-window")]
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test(arguments: [nil, ""] as [String?])
func sendRejectsUnreadableNamesEvenWithOneExactMatch(name: String?) {
    let ui = FakeSendUI()
    ui.rows.append(SendChatRow(element: "unknown-row", name: name, isSelfChat: false))
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.openedRows.isEmpty)
    #expect(ui.writes.isEmpty)
    #expect(ui.returnCount == 0)
}

@Test(arguments: ["focus", "value", "title", "main"])
func sendChecksTargetAtSubmissionBoundary(change: String) {
    let ui = FakeSendUI()
    ui.beforeSubmit = { [unowned ui] in
        switch change {
        case "focus": ui.focused = false
        case "title": ui.currentWindows = [FakeSendUI.window("main"), FakeSendUI.window("alice-window", title: "Bob")]
        case "main": ui.currentWindows = [FakeSendUI.window("replacement-main"), FakeSendUI.window("alice-window", title: "Alice")]
        default: ui.storedMessage = "changed"
        }
    }
    #expect(throws: AutomationError.self) {
        try SendWorkflow(ui: ui).send(to: "Alice", message: "hello", selfChat: false)
    }
    #expect(ui.writes.count == 1)
    #expect(ui.returnCount == 0)
}
