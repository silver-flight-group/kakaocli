import CommonCrypto
import Foundation

/// Extracts device UUID and KakaoTalk user ID from the local system.
public enum DeviceInfo {

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

    /// Environment variable that forces a specific user ID, bypassing all detection.
    public static let userIdEnvVar = "KAKAOCLI_USER_ID"

    /// Path to the cached user ID file (`~/.kakaocli/userid.json`).
    static var userIdCachePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli")
            .appendingPathComponent("userid.json").path
    }

    private struct CachedUserId: Codable {
        var userId: Int
        var accountHash: String?
        var uuid: String?
    }

    /// Resolve the KakaoTalk user ID.
    ///
    /// Resolution order:
    /// 1. `KAKAOCLI_USER_ID` environment variable (explicit override).
    /// 2. Cached value from a previous run (validated against the active account).
    /// 3. Plist detection (may brute-force a SHA-512 pre-image — slow, so the result is cached).
    public static func userId() throws -> Int {
        // 1. Explicit override — trusted, and cached so it survives across processes.
        if let envId = userIdFromEnvironment() {
            cacheUserId(envId)
            return envId
        }

        // 2. Previously recovered value, revalidated so account switches self-heal.
        if let cached = cachedUserId() {
            return cached
        }

        // 3. Detect from the plist; persist whatever we find.
        if let detected = try detectUserId() {
            cacheUserId(detected)
            return detected
        }

        throw KakaoError.userIdNotFound(["Could not extract from FSChatWindowTransparency, revision key SHA-512, or FSChatWindowFrame_ keys"])
    }

    /// Extract the user ID from the KakaoTalk preferences plist.
    ///
    /// Tries multiple strategies in order:
    /// 1. FSChatWindowTransparency common suffix (legacy)
    /// 2. Direct key lookup (userId, user_id, etc.)
    /// 3. Recover userId by reversing the SHA-512 hash from plist revision keys
    /// 4. FSChatWindowFrame_ common suffix
    ///
    /// Returns `nil` if none of the strategies find a user ID.
    private static func detectUserId() throws -> Int? {
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
                    return id
                }
            }

            // Strategy 2: Direct key lookup
            let candidateKeys = ["userId", "user_id", "KAKAO_USER_ID", "userID"]
            for key in candidateKeys {
                if let id = plist[key] as? Int { return id }
                if let str = plist[key] as? String, let id = Int(str) { return id }
            }

            // Strategy 3: Recover userId from SHA-512 hash in plist revision keys.
            // Newer KakaoTalk stores SHA-512(userId) as a suffix on keys like
            // "DESIGNATEDFRIENDSREVISION:<sha512hex>". The active account has non-zero values.
            if let hash = activeAccountHash(from: plist) {
                // Fast path: check known candidate IDs (instant) before brute-forcing.
                if let match = candidateUserIds().first(where: { sha512Hex(String($0)) == hash }) {
                    return match
                }
                // Slow path: brute-force the pre-image. userIds are integers, so this
                // is bounded; it's parallelized and the result is cached by the caller.
                if let id = recoverUserIdFromSHA512(hexHash: hash) {
                    return id
                }
            }

            // Strategy 4: FSChatWindowFrame_ common suffix (newer KakaoTalk versions)
            let framePrefix = "NSWindow Frame FSChatWindowFrame_"
            let frameKeys = plist.keys.filter { $0.hasPrefix(framePrefix) }
            if frameKeys.count >= 2 {
                let suffixes = frameKeys.map { String($0.dropFirst(framePrefix.count)) }
                if let commonSuffix = longestCommonSuffix(suffixes), let id = Int(commonSuffix) {
                    return id
                }
            }
        }

        return nil
    }

    /// Read `KAKAOCLI_USER_ID` from the environment, if set to a positive integer.
    private static func userIdFromEnvironment() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[userIdEnvVar],
              let id = Int(raw.trimmingCharacters(in: .whitespaces)), id > 0 else {
            return nil
        }
        return id
    }

    /// Read a previously cached user ID, returning it only if it still matches the active account.
    public static func cachedUserId() -> Int? {
        guard let data = FileManager.default.contents(atPath: userIdCachePath),
              let cached = try? JSONDecoder().decode(CachedUserId.self, from: data) else {
            return nil
        }
        return isValidUserId(cached.userId) ? cached.userId : nil
    }

    /// Persist a recovered user ID so future runs skip detection entirely.
    public static func cacheUserId(_ id: Int) {
        guard id > 0 else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kakaocli")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = CachedUserId(userId: id, accountHash: activeAccountHash(), uuid: try? platformUUID())
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: URL(fileURLWithPath: userIdCachePath))
        }
    }

    /// Validate that a user ID belongs to the currently active account.
    ///
    /// Uses the cheap, definitive SHA-512 check when an account hash is available; otherwise
    /// falls back to deriving the database filename and checking it exists on disk. This makes
    /// a stale cache self-heal after an account switch instead of returning the wrong ID.
    public static func isValidUserId(_ id: Int) -> Bool {
        guard id > 0 else { return false }
        if let hash = activeAccountHash() {
            return sha512Hex(String(id)) == hash
        }
        // No account hash to compare against — verify by deriving the DB filename.
        if let uuid = try? platformUUID() {
            let dbName = KeyDerivation.databaseName(userId: id, uuid: uuid)
            let candidates = ["\(containerPath)/\(dbName)", "\(containerPath)/\(dbName).db"]
            if candidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                return true
            }
            // If no database is discoverable at all, we can't disprove the cache — trust it.
            return discoverDatabaseFile() == nil
        }
        return true
    }

    /// Hex-encoded SHA-512 of a string.
    static func sha512Hex(_ s: String) -> String {
        let data = Array(s.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512(data, CC_LONG(data.count), &hash)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Default brute-force timeout in seconds. Override with `KAKAOCLI_USERID_TIMEOUT`.
    static var defaultBruteForceTimeout: Double {
        if let raw = ProcessInfo.processInfo.environment["KAKAOCLI_USERID_TIMEOUT"],
           let val = Double(raw), val > 0 {
            return val
        }
        return 180
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
    ///
    /// KakaoTalk stores SHA-512(userId) as hex in plist keys. userIds are integers, so the
    /// pre-image is recoverable by search. The work is split across all CPU cores and reports
    /// progress to stderr; large IDs (hundreds of millions) resolve in seconds to tens of
    /// seconds. Callers should cache the result so this runs at most once.
    ///
    /// - Parameters:
    ///   - hexHash: 128-char hex SHA-512 digest to invert.
    ///   - timeout: Wall-clock budget in seconds (default: `KAKAOCLI_USERID_TIMEOUT` or 180).
    ///   - maxId: Upper bound (exclusive) for the search.
    public static func recoverUserIdFromSHA512(hexHash: String,
                                               timeout: Double? = nil,
                                               maxId: Int = 1_000_000_000) -> Int? {
        guard hexHash.count == 128 else { return nil }
        // Parse target hash to bytes
        var targetBytes = [UInt8](repeating: 0, count: 64)
        let hexChars = Array(hexHash)
        for i in 0..<64 {
            guard let byte = UInt8(String(hexChars[i*2...i*2+1]), radix: 16) else { return nil }
            targetBytes[i] = byte
        }

        let target = targetBytes  // immutable snapshot for the concurrent closure
        let budget = timeout ?? defaultBruteForceTimeout
        let startTime = CFAbsoluteTimeGetCurrent()
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let state = BruteForceState()

        // Each worker strides by `workers`, so together they cover [0, maxId).
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            var i = worker
            var sinceCheck = 0
            var lastReport = startTime
            while i < maxId {
                // Periodically check for stop / timeout (and report progress from worker 0).
                if sinceCheck >= 1_000_000 {
                    sinceCheck = 0
                    if state.isStopped() { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - startTime > budget {
                        state.stop()
                        return
                    }
                    if worker == 0 && now - lastReport >= 2 {
                        lastReport = now
                        let msg = "kakaocli: recovering user ID… \(i / 1_000_000)M checked (\(Int(now - startTime))s)\n"
                        FileHandle.standardError.write(Data(msg.utf8))
                    }
                }
                let data = Array(String(i).utf8)
                CC_SHA512(data, CC_LONG(data.count), &hash)
                if hash == target {
                    state.record(i)
                    return
                }
                i += workers
                sinceCheck += 1
            }
        }
        return state.result()
    }

    /// Lock-guarded shared state for the parallel brute-force search.
    private final class BruteForceState: @unchecked Sendable {
        private let lock = NSLock()
        private var found: Int?
        private var stopped = false

        func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func record(_ id: Int) { lock.lock(); found = id; stopped = true; lock.unlock() }
        func result() -> Int? { lock.lock(); defer { lock.unlock() }; return found }
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
