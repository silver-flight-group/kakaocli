import ArgumentParser
import Foundation
import KakaoCore

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show KakaoTalk installation and connection status"
    )

    func run() throws {
        let appPath = AppLifecycle.appPath
        let containerExists = FileManager.default.fileExists(atPath: DeviceInfo.containerPath)
        let globalPlistExists = FileManager.default.fileExists(atPath: DeviceInfo.preferencesPath)
        let containerPlistExists = FileManager.default.fileExists(atPath: DeviceInfo.containerPreferencesPath)

        print("KakaoTalk Status")
        print("================")
        print("App installed:      \(FileManager.default.fileExists(atPath: appPath) ? "Yes" : "No")")
        print("Container exists:   \(containerExists ? "Yes" : "No")")
        print("Preferences exist:  \(globalPlistExists || containerPlistExists ? "Yes" : "No")\(containerPlistExists && !globalPlistExists ? " (container only)" : "")")

        // Check UUID
        do {
            let uuid = try DeviceInfo.platformUUID()
            print("Device UUID:        \(uuid)")
        } catch {
            print("Device UUID:        ERROR - \(error)")
        }

        // User ID detection
        do {
            let uid = try DeviceInfo.userId()
            print("User ID:            \(uid)")
        } catch {
            let candidates = DeviceInfo.candidateUserIds()
            if candidates.isEmpty {
                print("User ID:            NOT FOUND")
            } else {
                print("User ID:            NOT FOUND (candidates: \(candidates.map(String.init).joined(separator: ", ")))")
            }
        }

        // Database files
        if containerExists {
            let dbCount = DeviceInfo.countDatabaseFiles()
            print("Database files:     \(dbCount)")
            if let dbPath = DeviceInfo.discoverDatabaseFile() {
                let dbName = (dbPath as NSString).lastPathComponent
                print("Database name:      \(dbName)")
            }
        }

        // Active account hash
        if let hash = DeviceInfo.activeAccountHash() {
            print("Account hash:       \(hash.prefix(40))...")
        }

        // Check permissions
        print("\nPermissions")
        print("-----------")
        let hasFullDisk = containerExists && FileManager.default.isReadableFile(atPath: DeviceInfo.containerPath)
        print("Full Disk Access:   \(hasFullDisk ? "Likely OK" : "May be needed")")

        // App lifecycle
        print("\nApp Lifecycle")
        print("-------------")
        let appState = AppLifecycle.detectState()
        print("App state:          \(appState.rawValue)")
        let creds = CredentialStore()
        print("Stored credentials: \(creds.hasCredentials ? "Yes" : "No")")
    }
}
