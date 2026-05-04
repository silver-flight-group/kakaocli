import ArgumentParser
import Foundation
import KakaoCore

struct LeaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leave",
        abstract: "Leave a KakaoTalk chatroom via UI automation"
    )

    @Argument(help: "Chat name to leave (substring match)")
    var chat: String

    @Flag(name: .long, help: "Show what would happen without actually leaving")
    var dryRun = false

    func run() throws {
        if dryRun {
            print("DRY RUN: Would leave chatroom '\(chat)'")
            print("Steps: activate KakaoTalk -> find chat '\(chat)' -> open menu -> Leave chatroom -> confirm")
            return
        }
        try AutomationPermissions.requireForSend()
        try KakaoAutomator().leaveChat(to: chat)
        print("Left chatroom '\(chat)'.")
    }
}
