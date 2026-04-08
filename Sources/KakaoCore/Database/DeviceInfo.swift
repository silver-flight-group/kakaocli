import CommonCrypto
import Foundation

/// Extracts device UUID and KakaoTalk user ID from the local system.
public enum DeviceInfo {

    /// In-process cache for the discovered user ID.
    nonisolated(unsafe) static var cachedUserId: Int? = nil

    /// Path to the on-disk user ID cache file.
    public static var userIdCachePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.kakaocli/userid"
    }

    /// Persist the user ID to disk and in-process cache.
    static func saveUserIdCache(_ id: Int) {
        cachedUserId = id
        let path = userIdCachePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? String(id).write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Clear both the in-process cache and the on-disk cache file.
    public static func clearUserIdCache() {
        cachedUserId = nil
        try? FileManager.default.removeItem(atPath: userIdCachePath)
    }

    /// Get the IOPlatformUUID from IORegistry.
    public static func platformUUID() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Parse: "IOPlatformUUID" = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        guard let range = output.range(of: #""IOPlatformUUID" = "([^"]+)""#, options: .regularExpression),
              let uuidRange = output[range].range(of: #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#, options: .regularExpression)
        else {
            throw KakaoError.uuidNotFound
        }
        return String(output[uuidRange])
    }

    /// Path to the KakaoTalk preferences plist.
    public static var preferencesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Preferences/com.kakao.KakaoTalkMac.plist"
    }

    /// Path to the KakaoTalk container data directory.
    public static var containerPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Application Support/com.kakao.KakaoTalkMac"
    }

    /// Path to the container preferences plist (has more data than the global one).
    public static var containerPreferencesPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefDir = "\(home)/Library/Containers/com.kakao.KakaoTalkMac/Data/Library/Preferences"
        // Find the hex-suffixed plist: com.kakao.KakaoTalkMac.<HEX>.plist
        if let files = try? FileManager.default.contentsOfDirectory(atPath: prefDir) {
            for file in files where file.hasPrefix("com.kakao.KakaoTalkMac.") && file.hasSuffix(".plist") && file != "com.kakao.KakaoTalkMac.plist" {
                return "\(prefDir)/\(file)"
            }
        }
        return "\(prefDir)/com.kakao.KakaoTalkMac.plist"
    }

    /// Extract user ID from the KakaoTalk preferences plist.
    ///
    /// Tries multiple strategies in order:
    /// 0. In-process cache, then on-disk cache (~/.kakaocli/userid)
    /// 1. FSChatWindowTransparency common suffix (legacy)
    /// 2. Direct key lookup (userId, user_id, etc.)
    /// 3. Recover userId by reversing SHA-512 hash from plist revision keys
    /// 4. FSChatWindowFrame_ common suffix
    public static func userId() throws -> Int {
        // Strategy 0: Return from in-process cache first
        if let cached = cachedUserId {
            return cached
        }

        // Strategy 0b: Read from on-disk cache
        let cachePath = userIdCachePath
        if FileManager.default.fileExists(atPath: cachePath),
           let contents = try? String(contentsOfFile: cachePath, encoding: .utf8),
           let id = Int(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
            cachedUserId = id
            return id
        }

        let plistPaths = [containerPreferencesPath, preferencesPath]
        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath) else { continue }

            let url = URL(fileURLWithPath: plistPath)
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                continue
            }

            // Strategy 1: Extract common suffix from FSChatWindowTransparency keys
            let transparencyPrefix = "FSChatWindowTransparency"
            let fsChatKeys = plist.keys.filter { $0.hasPrefix(transparencyPrefix) }
            if fsChatKeys.count >= 2 {
                let suffixes = fsChatKeys.map { String($0.dropFirst(transparencyPrefix.count)) }
                if let commonSuffix = longestCommonSuffix(suffixes), let id = Int(commonSuffix) {
                    saveUserIdCache(id)
                    return id
                }
            }

            // Strategy 2: Direct key lookup
            let candidateKeys = ["userId", "user_id", "KAKAO_USER_ID", "userID"]
            for key in candidateKeys {
                if let id = plist[key] as? Int {
                    saveUserIdCache(id)
                    return id
                }
                if let str = plist[key] as? String, let id = Int(str) {
                    saveUserIdCache(id)
                    return id
                }
            }

            // Strategy 3: Recover userId from SHA-512 hash in plist revision keys.
            // Newer KakaoTalk stores SHA-512(userId) as a suffix on keys like
            // "DESIGNATEDFRIENDSREVISION:<sha512hex>". The active account has non-zero values.
            // We brute-force the pre-image since userIds are typically small integers.
            if let hash = activeAccountHash(from: plist) {
                if let id = recoverUserIdFromSHA512(hexHash: hash) {
                    saveUserIdCache(id)
                    return id
                }
            }

            // Strategy 4: FSChatWindowFrame_ common suffix (newer KakaoTalk versions)
            let framePrefix = "NSWindow Frame FSChatWindowFrame_"
            let frameKeys = plist.keys.filter { $0.hasPrefix(framePrefix) }
            if frameKeys.count >= 2 {
                let suffixes = frameKeys.map { String($0.dropFirst(framePrefix.count)) }
                if let commonSuffix = longestCommonSuffix(suffixes), let id = Int(commonSuffix) {
                    saveUserIdCache(id)
                    return id
                }
            }
        }

        throw KakaoError.userIdNotFound(["Could not extract from FSChatWindowTransparency, revision key SHA-512, or FSChatWindowFrame_ keys"])
    }

    /// Read AlertKakaoIDsList from plist as candidate user IDs.
    public static func candidateUserIds() -> [Int] {
        let plistPaths = [containerPreferencesPath, preferencesPath]
        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let ids = plist["AlertKakaoIDsList"] as? [Any] else { continue }

            return ids.compactMap { item -> Int? in
                if let id = item as? Int { return id > 0 ? id : nil }
                if let str = item as? String, let id = Int(str) { return id > 0 ? id : nil }
                return nil
            }
        }
        return []
    }

    /// Discover database file by scanning the container for 78-char hex filenames.
    public static func discoverDatabaseFile() -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { return nil }
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}$")
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            if hexPattern.firstMatch(in: entry, range: range) != nil {
                return "\(containerPath)/\(entry)"
            }
        }
        // Also check files with .db extension that have hex basename
        let hexDbPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}\\.db$")
        for entry in entries {
            let range = NSRange(entry.startIndex..., in: entry)
            if hexDbPattern.firstMatch(in: entry, range: range) != nil {
                return "\(containerPath)/\(entry)"
            }
        }
        return nil
    }

    /// Count database files in the container (78-char hex files or .db files).
    public static func countDatabaseFiles() -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: containerPath) else { return 0 }
        let hexPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{78}(\\.db)?$")
        return entries.filter { entry in
            let range = NSRange(entry.startIndex..., in: entry)
            return hexPattern.firstMatch(in: entry, range: range) != nil
        }.count
    }

    /// Extract the active account SHA-512 hash from plist revision keys.
    /// Keys like `DESIGNATEDFRIENDSREVISION:<sha512hex>` appear with non-zero values for the active account.
    /// SHA-512("0") is the default/empty account hash.
    public static func activeAccountHash() -> String? {
        let plistPaths = [containerPreferencesPath, preferencesPath]
        for plistPath in plistPaths {
            guard FileManager.default.fileExists(atPath: plistPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            if let hash = activeAccountHash(from: plist) {
                return hash
            }
        }
        return nil
    }

    private static func activeAccountHash(from plist: [String: Any]) -> String? {
        // SHA-512("0") = 31bca02... is the default/empty account
        let emptyHash = "31bca02094eb78126a517b206a88c73cfa9ec6f704c7030d18212cace820f025f00bf0ea68dbf3f3a5436ca63b53bf7bf80ad8d5de7d8359d0b7fed9dbc3ab99"
        let prefix = "DESIGNATEDFRIENDSREVISION:"
        for (key, val) in plist where key.hasPrefix(prefix) {
            let hash = String(key.dropFirst(prefix.count))
            if hash == emptyHash { continue }
            let intVal: Int
            if let v = val as? Int { intVal = v }
            else if let v = val as? Double { intVal = Int(v) }
            else { intVal = 0 }
            if intVal != 0 { return hash }
        }
        return nil
    }

    /// Recover a userId by brute-forcing the SHA-512 pre-image.
    /// KakaoTalk stores SHA-512(userId) as hex in plist keys. Since userIds are
    /// typically small integers, this is fast (< 1 second for IDs under 1M).
    /// Searches up to 1 billion with a 300-second timeout.
    public static func recoverUserIdFromSHA512(hexHash: String) -> Int? {
        guard hexHash.count == 128 else { return nil }
        // Parse target hash to bytes
        var targetBytes = [UInt8](repeating: 0, count: 64)
        let hexChars = Array(hexHash)
        for i in 0..<64 {
            guard let byte = UInt8(String(hexChars[i*2...i*2+1]), radix: 16) else { return nil }
            targetBytes[i] = byte
        }

        fputs("Could not find user ID from plist. Starting SHA-512 brute-force search (this may take a few minutes)...\n", stderr)

        let startTime = CFAbsoluteTimeGetCurrent()
        let maxId = 1_000_000_000
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))

        for i in 0..<maxId {
            let s = String(i)
            let data = Array(s.utf8)
            CC_SHA512(data, CC_LONG(data.count), &hash)
            if hash == targetBytes {
                let elapsed = Int(CFAbsoluteTimeGetCurrent() - startTime)
                fputs("Found user ID: \(i) (cached to ~/.kakaocli/userid)\n", stderr)
                _ = elapsed  // suppress unused warning; elapsed logged above via Found message
                return i
            }
            // Progress + timeout every 5M iterations
            if i % 5_000_000 == 0 && i > 0 {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let millions = i / 1_000_000
                fputs("  Searching... \(millions)m checked (\(Int(elapsed))s)\n", stderr)
                if elapsed > 300 { return nil }
            }
        }
        return nil
    }

    private static func longestCommonSuffix(_ strings: [String]) -> String? {
        guard let first = strings.first else { return nil }
        let reversed = strings.map { String($0.reversed()) }
        var commonLen = 0
        for i in reversed[0].indices {
            let ch = reversed[0][i]
            if reversed.allSatisfy({ i < $0.endIndex && $0[i] == ch }) {
                commonLen += 1
            } else {
                break
            }
        }
        guard commonLen > 0 else { return nil }
        return String(first.suffix(commonLen))
    }
}

public enum KakaoError: Error, CustomStringConvertible {
    case uuidNotFound
    case plistNotFound(String)
    case plistParseError
    case userIdNotFound([String])
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case sqlError(String)
    case kakaoTalkNotInstalled

    public var description: String {
        switch self {
        case .uuidNotFound:
            return "Could not read IOPlatformUUID from ioreg"
        case .plistNotFound(let path):
            return "KakaoTalk preferences not found at \(path). Is KakaoTalk installed?"
        case .plistParseError:
            return "Failed to parse KakaoTalk preferences plist"
        case .userIdNotFound(let keys):
            return "Could not find user ID in plist. Available keys: \(keys.joined(separator: ", "))"
        case .databaseNotFound(let path):
            return "KakaoTalk database not found at \(path)"
        case .databaseOpenFailed(let msg):
            return "Failed to open database: \(msg)"
        case .sqlError(let msg):
            return "SQL error: \(msg)"
        case .kakaoTalkNotInstalled:
            return "KakaoTalk.app is not installed"
        }
    }
}
