import ArgumentParser
import KakaoCore

@main
struct KakaoCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakaocli",
        abstract: "KakaoTalk CLI for AI agents",
        version: kakaocliVersion,
        subcommands: [
            AuthCommand.self,
            ChatsCommand.self,
            HarvestCommand.self,
            InspectCommand.self,
            LoginCommand.self,
            MessagesCommand.self,
            QueryCommand.self,
            SchemaCommand.self,
            SearchCommand.self,
            SendCommand.self,
            StatusCommand.self,
            SyncCommand.self,
        ]
    )
}
