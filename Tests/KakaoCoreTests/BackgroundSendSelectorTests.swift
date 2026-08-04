import ApplicationServices
import Foundation
import Testing
@testable import KakaoCore

@Suite("Fail-closed send selection")
struct BackgroundSendSelectorTests {
    @Test("rejects every already-open room, including an exact empty-title match")
    func openRooms() {
        for rooms in [
            [OpenRoomEvidence(title: "Target", composerCount: 1, composerText: "")],
            [OpenRoomEvidence(title: "Other", composerCount: 1, composerText: "")],
            [
                OpenRoomEvidence(title: "Target", composerCount: 1, composerText: ""),
                OpenRoomEvidence(title: "Other", composerCount: 1, composerText: ""),
            ],
        ] {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.preparation(
                    expectedTitle: "Target",
                    openRooms: rooms,
                    matchingRowCount: 1
                )
            }
        }
    }

    @Test("opens only one exact visible row")
    func rowIdentity() throws {
        #expect(try BackgroundSendSelector.preparation(
            expectedTitle: "Target",
            openRooms: [],
            matchingRowCount: 1
        ) == .openExactRow)
        for count in [0, 2, 3] {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.preparation(
                    expectedTitle: "Target",
                    openRooms: [],
                    matchingRowCount: count
                )
            }
        }
    }

    @Test("recognizes only an exact selected Chats navigation control")
    func chatsNavigation() {
        #expect(BackgroundSendSelector.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: kAXCheckBoxRole as String,
                identifier: "chatrooms",
                title: nil,
                description: nil,
                selected: true
            )
        ))
        #expect(BackgroundSendSelector.isSelectedChatsNavigation(
            NavigationControlEvidence(
                role: kAXButtonRole as String,
                identifier: nil,
                title: "Chats",
                description: nil,
                selected: true
            )
        ))
        for evidence in [
            NavigationControlEvidence(
                role: kAXCheckBoxRole as String,
                identifier: "contacts",
                title: "Chats",
                description: nil,
                selected: true
            ),
            NavigationControlEvidence(
                role: kAXCheckBoxRole as String,
                identifier: "chatrooms",
                title: nil,
                description: nil,
                selected: false
            ),
            NavigationControlEvidence(
                role: kAXButtonRole as String,
                identifier: nil,
                title: "Contacts",
                description: nil,
                selected: true
            ),
        ] {
            #expect(!BackgroundSendSelector.isSelectedChatsNavigation(evidence))
        }
    }

    @Test("final room proof binds the application, windows, title, composer, focus, and body")
    func finalRoom() throws {
        let valid = FinalRoomEvidence(
            applicationRunning: true,
            exactWindowSet: true,
            mainWindowIdentifier: "Main Window",
            roomTitle: "Target",
            composerCount: 1,
            composerIdentityMatches: true,
            composerFocused: true,
            composerBody: "exact bytes"
        )
        try BackgroundSendSelector.verifyFinalRoom(
            expectedTitle: "Target",
            expectedBody: "exact bytes",
            evidence: valid
        )
        let invalid = [
            FinalRoomEvidence(
                applicationRunning: false,
                exactWindowSet: true,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Target",
                composerCount: 1,
                composerIdentityMatches: true,
                composerFocused: true,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: false,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Target",
                composerCount: 1,
                composerIdentityMatches: true,
                composerFocused: true,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: true,
                mainWindowIdentifier: "Other",
                roomTitle: "Target",
                composerCount: 1,
                composerIdentityMatches: true,
                composerFocused: true,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: true,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Wrong",
                composerCount: 1,
                composerIdentityMatches: true,
                composerFocused: true,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: true,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Target",
                composerCount: 2,
                composerIdentityMatches: true,
                composerFocused: true,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: true,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Target",
                composerCount: 1,
                composerIdentityMatches: false,
                composerFocused: true,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: true,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Target",
                composerCount: 1,
                composerIdentityMatches: true,
                composerFocused: false,
                composerBody: "exact bytes"
            ),
            FinalRoomEvidence(
                applicationRunning: true,
                exactWindowSet: true,
                mainWindowIdentifier: "Main Window",
                roomTitle: "Target",
                composerCount: 1,
                composerIdentityMatches: true,
                composerFocused: true,
                composerBody: "changed"
            ),
        ]
        for evidence in invalid {
            #expect(throws: AutomationError.self) {
                try BackgroundSendSelector.verifyFinalRoom(
                    expectedTitle: "Target",
                    expectedBody: "exact bytes",
                    evidence: evidence
                )
            }
        }
    }

    @Test("selects exact localized controls only and never guesses by position")
    func exactControls() {
        let candidates = [
            BackgroundSendControlCandidate(index: 0, label: "", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 1, label: "전송", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 2, label: "Send later", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 3, label: "Send", enabled: false, supportsPress: true),
        ]
        #expect(BackgroundSendSelector.exactSendControlIndices(from: candidates) == [1])
    }

    @Test("multiple exact controls remain ambiguous")
    func duplicateControls() {
        let candidates = [
            BackgroundSendControlCandidate(index: 0, label: "Send", enabled: true, supportsPress: true),
            BackgroundSendControlCandidate(index: 1, label: "전송", enabled: true, supportsPress: true),
        ]
        #expect(BackgroundSendSelector.exactSendControlIndices(from: candidates) == [0, 1])
    }

    @Test("send sources contain no activation, raising, pointer, global input, or Keychain calls")
    func sourceSafetyGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let automator = try String(
            contentsOf: repository.appendingPathComponent("Sources/KakaoCore/Automation/KakaoAutomator.swift"),
            encoding: .utf8
        )
        let command = try String(
            contentsOf: repository.appendingPathComponent("Sources/KakaoCLI/Commands/SendCommand.swift"),
            encoding: .utf8
        )
        for prohibited in [
            ".activate(",
            "kAXRaiseAction",
            "CGWarpMouseCursorPosition",
            ".post(tap:",
            "CGEvent(mouseEventSource",
            "/usr/bin/security",
        ] {
            #expect(!automator.contains(prohibited))
            #expect(!command.contains(prohibited))
        }
        #expect(!command.contains("foreground"))
        #expect(!command.contains("@Argument"))
        #expect(!command.contains("var key"))
    }
}
