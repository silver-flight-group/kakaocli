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

    @Option(name: .long, help: "Override user ID instead of reading from plist")
    var userId: Int?

    @Option(name: .long, help: "Override device UUID instead of reading from ioreg")
    var uuid: String?

    func run() throws {
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

        // 4. Discover database file(s) — more than one can exist if several KakaoTalk
        // accounts have used this Mac over time (shared machine, employee turnover).
        let discoveredDbs = DeviceInfo.discoverDatabaseFiles()
        for db in discoveredDbs {
            print("Discovered DB: \((db as NSString).lastPathComponent)")
        }

        // 5. Try the standard derived path first, but only trust it if it actually opens —
        // a file existing at the derived name doesn't prove the derived key is right (stale
        // plist state from a previous account on this Mac can point at someone else's DB).
        if let uid {
            let dbName = KeyDerivation.databaseName(userId: uid, uuid: deviceUUID)
            let candidates = [
                "\(DeviceInfo.containerPath)/\(dbName)",
                "\(DeviceInfo.containerPath)/\(dbName).db",
            ]
            if let dbPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                let secureKey = KeyDerivation.secureKey(userId: uid, uuid: deviceUUID)
                let reader = DatabaseReader(databasePath: dbPath)
                if reader.tryOpen(key: secureKey) {
                    print("Database found: \(dbPath)")
                    let tables = try reader.schema()
                    print("\nDatabase opened successfully!")
                    print("Tables found: \(tables.count)")
                    for table in tables {
                        print("  - \(table.name)")
                    }
                    reader.close()
                    return
                }
                if verbose {
                    print("Derived DB name matched \(dbPath) but the derived key could not open it — trying other candidates")
                }
            } else if verbose {
                print("Derived DB name does not match any file")
            }
        }

        // 6. Try every discovered DB against every candidate userId's key.
        if !discoveredDbs.isEmpty {
            var candidateIds = uid.map { [$0] } ?? [Int]()
            candidateIds += DeviceInfo.candidateUserIds().filter { !candidateIds.contains($0) }

            if !candidateIds.isEmpty {
                print("\nTrying candidate user IDs against discovered DB(s)...")
                for db in discoveredDbs {
                    for candidate in candidateIds {
                        let candidateKey = KeyDerivation.secureKey(userId: candidate, uuid: deviceUUID)
                        let reader = DatabaseReader(databasePath: db)
                        if reader.tryOpen(key: candidateKey) {
                            print("  \((db as NSString).lastPathComponent) userId=\(candidate): OK")
                            let tables = try reader.schema()
                            print("\nDatabase opened successfully with userId=\(candidate)!")
                            print("Tables found: \(tables.count)")
                            for table in tables {
                                print("  - \(table.name)")
                            }
                            reader.close()
                            return
                        } else if verbose {
                            print("  \((db as NSString).lastPathComponent) userId=\(candidate): key mismatch")
                        }
                    }
                }
            }

            // None of the candidate keys worked against any discovered DB
            print("\nNo candidate user ID produced a valid key for any discovered database.")
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
}
