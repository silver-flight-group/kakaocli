import Foundation

/// Manages KakaoTalk login credentials using macOS Keychain.
public final class CredentialStore: Sendable {

    private static let service = "com.kakaocli.credentials"
    private static let emailAccount = "kakaotalk-email"
    private static let passwordAccount = "kakaotalk-password"

    public init() {}

    // MARK: - Read

    public var email: String? {
        Self.readKeychain(account: Self.emailAccount)
    }

    public var password: String? {
        Self.readKeychain(account: Self.passwordAccount)
    }

    public var hasCredentials: Bool {
        email != nil && password != nil
    }

    // MARK: - Write

    public func save(email: String, password: String) throws {
        try Self.writeKeychain(account: Self.emailAccount, value: email)
        try Self.writeKeychain(account: Self.passwordAccount, value: password)
    }

    public func clear() {
        Self.deleteKeychain(account: Self.emailAccount)
        Self.deleteKeychain(account: Self.passwordAccount)
    }

    // MARK: - Keychain Primitives

    private static func readKeychain(account: String) -> String? {
        // Use `security` CLI to avoid code-signing ACL issues with swift run.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-g",  // print password to stderr (see parsePasswordLine)
        ]
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else { return nil }
            return output.split(separator: "\n")
                .first { $0.hasPrefix("password: ") }
                .flatMap { parsePasswordLine(String($0)) }
        } catch {
            return nil
        }
    }

    /// Parse the `password:` line printed by `security find-generic-password -g`.
    /// Printable ASCII comes as `password: "value"`; anything else (e.g. Korean) as
    /// `password: 0x<HEX>  "<octal escapes>"`. `-w` would print bare hex for the latter,
    /// which is indistinguishable from an ASCII password that happens to look like hex.
    static func parsePasswordLine(_ line: String) -> String? {
        let body = line.dropFirst("password: ".count)
        if body.hasPrefix("0x") {
            let hex = body.dropFirst(2).prefix { $0.isHexDigit }
            guard hex.count % 2 == 0 else { return nil }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return String(bytes: bytes, encoding: .utf8)
        }
        guard body.count >= 2, body.hasPrefix("\""), body.hasSuffix("\"") else { return nil }
        return String(body.dropFirst().dropLast())
    }

    private static func writeKeychain(account: String, value: String) throws {
        // Use `security` CLI to avoid code-signing ACL issues with swift run.
        // The Security framework ties keychain items to the signing identity of the binary,
        // which changes every time swift run rebuilds to a new path.
        //
        // The command is fed through `security -i` on stdin rather than as arguments,
        // so the secret never appears in the process list (`ps`).
        let command = try addPasswordCommand(service: service, account: account, value: value)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(command.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CredentialError.keychainError(OSStatus(process.terminationStatus))
        }
    }

    /// Build an `add-generic-password` line for `security -i`, double-quoting the value.
    /// Interactive mode is line-based, so a value containing a newline can't be stored.
    static func addPasswordCommand(service: String, account: String, value: String) throws -> String {
        guard !value.contains(where: \.isNewline) else {
            throw CredentialError.invalidValue("must not contain line breaks")
        }
        let quoted = "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return "add-generic-password -s \(service) -a \(account) -U -w \(quoted)\n"
    }

    private static func deleteKeychain(account: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "delete-generic-password",
            "-s", service,
            "-a", account,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

public enum CredentialError: Error, CustomStringConvertible {
    case keychainError(OSStatus)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .keychainError(let status):
            return "Keychain error: exit code \(status)"
        case .invalidValue(let reason):
            return "Invalid credential: \(reason)"
        }
    }
}
