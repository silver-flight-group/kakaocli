import ArgumentParser
import Foundation
import KakaoCore

struct SchemaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schema",
        abstract: "Dump the database schema (for reverse engineering)"
    )

    @Option(name: .long, help: "Path to database file")
    var db: String?

    @Option(name: .long, help: "Database encryption key")
    var key: String?

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    func run() throws {
        let reader = try openDatabase(dbPath: db, key: key, userId: userId)
        defer { reader.close() }

        let tables = try reader.schema()
        if tables.isEmpty {
            print("No tables found (database may be encrypted).")
            return
        }

        for table in tables {
            print("-- \(table.name)")
            print("\(table.sql);")
            print()
        }
    }
}
