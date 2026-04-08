import ArgumentParser
import Foundation
import KakaoCore

struct AuthCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Derive keys and verify database access"
    )

    @Flag(name: .long, help: "Show derived values (key, db name) for debugging")
    var verbose = false

    @Flag(name: .long, help: "Force userId re-discovery by clearing the cache before running")
    var refresh = false

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    @Option(name: .long, help: "Override device UUID instead of reading from ioreg")
    var uuid: String?

    func run() throws {
        // 0. If --refresh, clear cached userId before any discovery
        if refresh {
            DeviceInfo.clearUserIdCache()
        }

        // 1. Get device UUID
        let deviceUUID: String
        if let override = uuid {
            deviceUUID = override
        } else {
            deviceUUID = try DeviceInfo.platformUUID()
        }
        print("UUID: \(deviceUUID)")

        // 2. Get user ID
        let uid: Int?
        if let override = userId {
            uid = override
            print("User ID: \(override) (override)")
        } else {
            do {
                let detected = try DeviceInfo.userId()
                uid = detected
                print("User ID: \(detected)")
            } catch {
                uid = nil
                let candidates = DeviceInfo.candidateUserIds()
                print("User ID: auto-detection failed")
                if !candidates.isEmpty {
                    print("  Candidates from AlertKakaoIDsList: \(candidates.map(String.init).joined(separator: ", "))")
                }
            }
        }

        // 3. Show derived values if we have a userId
        if let uid, verbose {
            let dbName = KeyDerivation.databaseName(userId: uid, uuid: deviceUUID)
            let secureKey = KeyDerivation.secureKey(userId: uid, uuid: deviceUUID)
            print("Database name: \(dbName)")
            print("Secure key: \(secureKey.prefix(16))...")
        }

        // 4. Discover database file
        let discoveredDb = DeviceInfo.discoverDatabaseFile()
        if let discoveredDb {
            let name = (discoveredDb as NSString).lastPathComponent
            print("Discovered DB: \(name)")
        }

        // 5. Try to find working userId + key combination
        if let uid {
            let dbName = KeyDerivation.databaseName(userId: uid, uuid: deviceUUID)
            let candidates = [
                "\(DeviceInfo.containerPath)/\(dbName)",
                "\(DeviceInfo.containerPath)/\(dbName).db",
            ]
            if let dbPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                print("Database found: \(dbPath)")
                let secureKey = KeyDerivation.secureKey(userId: uid, uuid: deviceUUID)
                try verifyDatabase(path: dbPath, key: secureKey)
                return
            } else if verbose {
                print("Derived DB name does not match any file")
            }
        }

        // 6. Try discovered DB with candidate userIds
        if let discoveredDb {
            let candidateIds: [Int]
            if let uid {
                candidateIds = [uid] + DeviceInfo.candidateUserIds().filter { $0 != uid }
            } else {
                candidateIds = DeviceInfo.candidateUserIds()
            }

            if !candidateIds.isEmpty {
                print("\nTrying candidate user IDs against discovered DB...")
                for candidate in candidateIds {
                    let candidateKey = KeyDerivation.secureKey(userId: candidate, uuid: deviceUUID)
                    let reader = DatabaseReader(databasePath: discoveredDb)
                    if reader.tryOpen(key: candidateKey) {
                        print("  userId=\(candidate): OK")
                        let tables = try reader.schema()
                        print("\nDatabase opened successfully with userId=\(candidate)!")
                        print("Tables found: \(tables.count)")
                        for table in tables {
                            print("  - \(table.name)")
                        }
                        reader.close()
                        return
                    } else {
                        if verbose {
                            print("  userId=\(candidate): key mismatch")
                        }
                    }
                }
            }

            // None of the candidate keys worked
            print("\nNo candidate user ID produced a valid key.")
            print("The database file exists but could not be decrypted.")
            print("\nTo provide your user ID manually:")
            print("  kakaocli auth --user-id <YOUR_KAKAO_USER_ID>")
            print("\nTo find your user ID, check your KakaoTalk mobile app settings")
            print("or search your plist: defaults read com.kakao.KakaoTalkMac")
            throw ExitCode.failure
        }

        // 7. No DB found at all
        print("\nNo database file found in: \(DeviceInfo.containerPath)")
        let containerURL = URL(fileURLWithPath: DeviceInfo.containerPath)
        if let files = try? FileManager.default.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil) {
            print("Container contents:")
            for file in files where !file.lastPathComponent.hasSuffix("-shm") && !file.lastPathComponent.hasSuffix("-wal") {
                print("  \(file.lastPathComponent)")
            }
        } else {
            print("  Could not list directory (check Full Disk Access)")
        }
        throw ExitCode.failure
    }

    private func verifyDatabase(path: String, key: String) throws {
        let reader = DatabaseReader(databasePath: path)
        do {
            try reader.open(key: key)
            let tables = try reader.schema()
            print("\nDatabase opened successfully!")
            print("Tables found: \(tables.count)")
            for table in tables {
                print("  - \(table.name)")
            }
        } catch {
            print("\nFailed to open database: \(error)")
            print("This may mean the key is wrong or SQLCipher is needed.")
            print("Install SQLCipher: brew install sqlcipher")
        }
    }
}
