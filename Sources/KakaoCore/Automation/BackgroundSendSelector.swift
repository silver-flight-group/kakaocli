import ApplicationServices
import Foundation

struct OpenRoomEvidence: Equatable {
    let title: String
    let composerCount: Int
    let composerText: String
}

enum RoomPreparation: Equatable {
    case openExactRow
}

struct NavigationControlEvidence: Equatable {
    let role: String?
    let identifier: String?
    let title: String?
    let description: String?
    let selected: Bool
}

struct FinalRoomEvidence: Equatable {
    let applicationRunning: Bool
    let exactWindowSet: Bool
    let mainWindowIdentifier: String?
    let roomTitle: String?
    let composerCount: Int
    let composerIdentityMatches: Bool
    let composerFocused: Bool
    let composerBody: String?
}

enum BackgroundSendSelector {
    static func isSelectedChatsNavigation(_ evidence: NavigationControlEvidence) -> Bool {
        guard evidence.selected else { return false }
        if evidence.role == kAXCheckBoxRole as String,
           evidence.identifier == "chatrooms" {
            return true
        }
        guard evidence.role == kAXButtonRole as String
                || evidence.role == kAXRadioButtonRole as String else { return false }
        let acceptedLabels = Set(["chat", "chats", "채팅"])
        let labels = [evidence.title, evidence.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return labels.contains(where: acceptedLabels.contains)
    }

    static func preparation(
        expectedTitle _: String,
        openRooms: [OpenRoomEvidence],
        matchingRowCount: Int
    ) throws -> RoomPreparation {
        // A window title is not a stable chat identity. Different chats can
        // share one title, so an already-open room is never safe to reuse.
        guard openRooms.isEmpty else {
            throw AutomationError.preconditionFailed(
                "A chat room is already open; close it manually before sending"
            )
        }
        guard matchingRowCount == 1 else {
            throw AutomationError.preconditionFailed(
                matchingRowCount == 0
                    ? "The exact destination row is unavailable"
                    : "The destination label matches multiple rows"
            )
        }
        return .openExactRow
    }

    static func verifyFinalRoom(
        expectedTitle: String,
        expectedBody: String,
        evidence: FinalRoomEvidence
    ) throws {
        guard evidence.applicationRunning,
              evidence.exactWindowSet,
              evidence.mainWindowIdentifier == "Main Window",
              evidence.roomTitle == expectedTitle,
              evidence.composerCount == 1,
              evidence.composerIdentityMatches,
              evidence.composerFocused,
              evidence.composerBody == expectedBody else {
            throw AutomationError.preconditionFailed(
                "Room or composer identity changed before the send action"
            )
        }
    }

    static func exactSendControlIndices(from candidates: [BackgroundSendControlCandidate]) -> [Int] {
        let accepted = Set(["send", "전송"])
        return candidates.filter { candidate in
            candidate.enabled && candidate.supportsPress && accepted.contains(
                candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            )
        }.map(\.index)
    }
}

struct BackgroundSendControlCandidate {
    let index: Int
    let label: String
    let enabled: Bool
    let supportsPress: Bool
}
