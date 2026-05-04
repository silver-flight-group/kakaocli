import ArgumentParser
import Foundation
import KakaoCore

struct SendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message via UI automation"
    )

    @Argument(help: "Chat name to send to (substring match), or any value with --self")
    var chat: String

    @Argument(help: "Message text to send")
    var message: String

    @Flag(name: [.customLong("me")], help: "Send to self-chat (나와의 채팅) regardless of chat argument")
    var selfChat = false

    @Flag(name: .long, help: "Show what would happen without actually sending")
    var dryRun = false

    func run() throws {
        let automator = KakaoAutomator()
        let target = selfChat ? "self-chat" : chat
        if dryRun {
            print("DRY RUN: Would send to '\(target)': \(message)")
            print("Steps: activate KakaoTalk → find chat '\(target)' → type message → press Enter")
            return
        }
        try AutomationPermissions.requireForSend()
        try automator.sendMessage(to: chat, message: message, selfChat: selfChat)
        print("Message sent to '\(target)'.")
    }
}
