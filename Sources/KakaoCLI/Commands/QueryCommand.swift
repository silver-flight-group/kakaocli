import ArgumentParser
import Foundation
import KakaoCore

struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Run a raw SQL query (read-only)"
    )

    @Argument(help: "SQL query to execute")
    var sql: String

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key, userId: userId)
        defer { reader.close() }

        let results = try reader.rawQuery(sql)

        let encoder = JSONSerialization.self
        let data = try encoder.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
