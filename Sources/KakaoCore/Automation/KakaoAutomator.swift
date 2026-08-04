import AppKit
import ApplicationServices
import Foundation

protocol KakaoSubmitting: AnyObject, Sendable {
    /// A precondition error proves that no send action was invoked and any
    /// body written by this call was safely removed. All later uncertainty is
    /// reported as `outcomeUnknown` so callers never retry the UI action.
    func submit(chat: Chat, message: String) throws
}

/// Fail-closed KakaoTalk send UI. This path never launches or activates the
/// app, raises a window, moves the cursor, or posts global input.
public final class KakaoAutomator: KakaoSubmitting, @unchecked Sendable {
    public static let bundleId = "com.kakao.KakaoTalkMac"

    public init() {}

    /// Submit a message to a database-resolved chat. Database confirmation and
    /// durable request idempotency are handled by the caller.
    public func submit(chat: Chat, message: String) throws {
        guard !message.isEmpty else {
            throw AutomationError.preconditionFailed("Message cannot be empty")
        }
        guard let runningApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleId
        ).first else {
            throw AutomationError.preconditionFailed("KakaoTalk is not running; foreground it manually")
        }

        let processID = runningApp.processIdentifier
        let app = AXUIElementCreateApplication(processID)
        var windows = AXHelpers.windows(app)
        let mainWindows = windows.filter { AXHelpers.identifier($0) == "Main Window" }
        guard mainWindows.count == 1, let mainWindow = mainWindows.first else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's main window is not rendered; foreground it manually"
            )
        }
        guard let table = AXHelpers.verifiedSendChatListTable(mainWindow) else {
            throw AutomationError.preconditionFailed(
                "KakaoTalk's selected Chats tab and chat list could not be structurally verified"
            )
        }

        let rows = matchingRows(in: table, chat: chat)
        // Kakao labels the self row as "My Chat"/"나와의 채팅", while the
        // opened window uses the database-resolved current-user display name.
        let expectedTitle = chat.displayName
        let roomWindows = windows.filter { !CFEqual($0, mainWindow) }
        let evidence = roomWindows.map { window in
            let composers = composerCandidates(in: window)
            return OpenRoomEvidence(
                title: AXHelpers.title(window) ?? "",
                composerCount: composers.count,
                composerText: composers.first.flatMap(AXHelpers.value) ?? ""
            )
        }
        _ = try BackgroundSendSelector.preparation(
            expectedTitle: expectedTitle,
            openRooms: evidence,
            matchingRowCount: rows.count
        )

        guard let row = rows.first else {
            throw AutomationError.preconditionFailed("The chat list changed during destination resolution")
        }
        guard AXHelpers.selectRow(row, in: table) else {
            throw AutomationError.preconditionFailed("The exact destination row could not be verified as selected")
        }
        guard AXHelpers.focus(table), AXHelpers.isFocused(table) else {
            throw AutomationError.preconditionFailed("The chat list did not retain focus")
        }
        guard let openEvent = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
              let openRelease = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
            throw AutomationError.preconditionFailed("Could not create the KakaoTalk-targeted Return event")
        }

        let currentWindows = AXHelpers.windows(app)
        let currentTable = AXHelpers.verifiedSendChatListTable(mainWindow)
        let currentRows = currentTable.map { matchingRows(in: $0, chat: chat) } ?? []
        guard !runningApp.isTerminated,
              currentWindows.count == 1,
              currentWindows.first.map({ CFEqual($0, mainWindow) }) == true,
              let currentTable,
              CFEqual(currentTable, table),
              currentRows.count == 1,
              currentRows.first.map({ CFEqual($0, row) }) == true,
              AXHelpers.isExactlySelected(row, in: currentTable),
              AXHelpers.isFocused(currentTable) else {
            throw AutomationError.preconditionFailed("Destination selection changed before the room was opened")
        }
        openEvent.postToPid(processID)
        openRelease.postToPid(processID)

        let room = try waitForExactRoom(app: app, mainWindow: mainWindow, expectedTitle: expectedTitle)
        windows = AXHelpers.windows(app)
        guard windows.count == 2,
              windows.contains(where: { CFEqual($0, mainWindow) }),
              windows.contains(where: { CFEqual($0, room) }) else {
            throw AutomationError.preconditionFailed("An unrelated room appeared while opening the destination")
        }
        guard AXHelpers.title(room) == expectedTitle else {
            throw AutomationError.preconditionFailed("The opened room title does not exactly match the destination")
        }

        let composers = composerCandidates(in: room)
        guard composers.count == 1 else {
            throw AutomationError.preconditionFailed("The target does not expose one exact composer")
        }
        let composer = composers[0]
        guard AXHelpers.value(composer)?.isEmpty == true else {
            throw AutomationError.preconditionFailed("The target room contains an unsent draft")
        }

        var actionAttempted = false
        do {
            guard AXHelpers.setValue(composer, message), AXHelpers.value(composer) == message else {
                throw AutomationError.preconditionFailed("The composer did not accept the exact message")
            }
            guard AXHelpers.focus(composer), AXHelpers.isFocused(composer),
                  AXHelpers.value(composer) == message else {
                throw AutomationError.preconditionFailed("The exact composer did not retain focus and content")
            }

            let controls = exactSendControls(in: room)
            if controls.count == 1, let control = controls.first {
                guard finalRoomIsVerified(
                    application: runningApp,
                    app: app,
                    mainWindow: mainWindow,
                    room: room,
                    expectedTitle: expectedTitle,
                    composer: composer,
                    body: message
                ) else {
                    throw AutomationError.preconditionFailed("Room or composer identity changed before Send")
                }
                let finalControls = exactSendControls(in: room)
                guard finalControls.count == 1,
                      finalControls.first.map({ CFEqual($0, control) }) == true,
                      finalRoomIsVerified(
                          application: runningApp,
                          app: app,
                          mainWindow: mainWindow,
                          room: room,
                          expectedTitle: expectedTitle,
                          composer: composer,
                          body: message
                      ) else {
                    throw AutomationError.preconditionFailed("The exact Send control changed before invocation")
                }
                actionAttempted = true
                guard AXHelpers.performAction(control, kAXPressAction as String) else {
                    throw AutomationError.outcomeUnknown("The exact Send control did not acknowledge its action")
                }
            } else if controls.isEmpty {
                guard let sendEvent = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true),
                      let sendRelease = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: false) else {
                    throw AutomationError.preconditionFailed("Could not create the KakaoTalk-targeted Return event")
                }
                guard finalRoomIsVerified(
                    application: runningApp,
                    app: app,
                    mainWindow: mainWindow,
                    room: room,
                    expectedTitle: expectedTitle,
                    composer: composer,
                    body: message
                ), exactSendControls(in: room).isEmpty,
                   finalRoomIsVerified(
                       application: runningApp,
                       app: app,
                       mainWindow: mainWindow,
                       room: room,
                       expectedTitle: expectedTitle,
                       composer: composer,
                       body: message
                   ) else {
                    throw AutomationError.preconditionFailed(
                        "Room, composer, or Send-control state changed before Return"
                    )
                }
                actionAttempted = true
                sendEvent.postToPid(processID)
                sendRelease.postToPid(processID)
            } else {
                throw AutomationError.preconditionFailed("Multiple exact Send controls are exposed")
            }
        } catch {
            if !actionAttempted {
                let currentValue = AXHelpers.value(composer)
                let cleared = currentValue?.isEmpty == true
                    || (currentValue == message
                        && AXHelpers.setValue(composer, "")
                        && AXHelpers.value(composer)?.isEmpty == true)
                guard cleared else {
                    throw AutomationError.outcomeUnknown(
                        "No send action was invoked, but safe composer cleanup could not be proven"
                    )
                }
            }
            throw error
        }
    }

    private func waitForExactRoom(
        app: AXUIElement,
        mainWindow: AXUIElement,
        expectedTitle: String
    ) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let rooms = AXHelpers.windows(app).filter { !CFEqual($0, mainWindow) }
            if rooms.count == 1 {
                guard AXHelpers.title(rooms[0]) == expectedTitle else {
                    throw AutomationError.preconditionFailed("The newly opened room has the wrong title")
                }
                return rooms[0]
            }
            if rooms.count > 1 {
                throw AutomationError.preconditionFailed("Multiple rooms opened for one destination")
            }
        }
        throw AutomationError.preconditionFailed("The verified destination did not open")
    }

    private func matchingRows(in table: AXUIElement, chat: Chat) -> [AXUIElement] {
        chat.isSelfChat
            ? AXHelpers.selfChatRows(table)
            : AXHelpers.exactChatRows(table, name: chat.displayName)
    }

    private func finalRoomIsVerified(
        application: NSRunningApplication,
        app: AXUIElement,
        mainWindow: AXUIElement,
        room: AXUIElement,
        expectedTitle: String,
        composer: AXUIElement,
        body: String
    ) -> Bool {
        let windows = AXHelpers.windows(app)
        let composers = composerCandidates(in: room)
        do {
            try BackgroundSendSelector.verifyFinalRoom(
                expectedTitle: expectedTitle,
                expectedBody: body,
                evidence: FinalRoomEvidence(
                    applicationRunning: !application.isTerminated,
                    exactWindowSet: windows.count == 2
                        && windows.contains(where: { CFEqual($0, mainWindow) })
                        && windows.contains(where: { CFEqual($0, room) }),
                    mainWindowIdentifier: AXHelpers.identifier(mainWindow),
                    roomTitle: AXHelpers.title(room),
                    composerCount: composers.count,
                    composerIdentityMatches: composers.first.map({ CFEqual($0, composer) }) == true,
                    composerFocused: AXHelpers.isFocused(composer),
                    composerBody: AXHelpers.value(composer)
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func composerCandidates(in room: AXUIElement) -> [AXUIElement] {
        AXHelpers.findAll(room, role: "AXTextArea").filter { element in
            guard AXHelpers.isAttributeSettable(element, kAXValueAttribute as String) else { return false }
            if AXHelpers.identifier(element) == "_NS:51" { return true }
            let label = (AXHelpers.description(element) ?? "").lowercased()
            return label == "enter a message" || label == "메시지 입력"
        }
    }

    private func exactSendControls(in room: AXUIElement) -> [AXUIElement] {
        let buttons = AXHelpers.findAll(room, role: "AXButton")
        let candidates = buttons.enumerated().map { index, element in
            let labels = [AXHelpers.title(element), AXHelpers.description(element)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            return BackgroundSendControlCandidate(
                index: index,
                label: labels.count == 1 ? labels[0] : "",
                enabled: AXHelpers.boolAttribute(element, kAXEnabledAttribute as String) == true,
                supportsPress: AXHelpers.actionNames(element).contains(kAXPressAction as String)
            )
        }
        return BackgroundSendSelector.exactSendControlIndices(from: candidates).map { buttons[$0] }
    }
}

public enum AutomationError: Error, CustomStringConvertible {
    // Retained for non-send legacy commands such as harvest.
    case noWindows
    case chatNotFound(String)
    case preconditionFailed(String)
    case outcomeUnknown(String)

    public var description: String {
        switch self {
        case .noWindows: return "No KakaoTalk windows found"
        case .chatNotFound(let name): return "Chat not found: \(name)"
        case .preconditionFailed(let message): return "Send precondition failed: \(message)"
        case .outcomeUnknown(let message): return "Send outcome unknown: \(message)"
        }
    }
}
