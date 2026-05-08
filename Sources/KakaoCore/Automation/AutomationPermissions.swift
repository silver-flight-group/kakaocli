import ApplicationServices
import Foundation

public enum AutomationPermissionStatus: Equatable {
    case granted
    case denied(String?)
    case unknown(String?)

    public var label: String {
        switch self {
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .unknown:
            return "Unknown"
        }
    }

    public var details: String? {
        switch self {
        case .granted:
            return nil
        case .denied(let details), .unknown(let details):
            return details
        }
    }
}

public struct AutomationPermissionReport {
    public let binaryPath: String
    public let accessibilityTrusted: Bool
    public let systemEventsAutomation: AutomationPermissionStatus
}

public enum AutomationPermissionError: Error, CustomStringConvertible {
    case accessibilityDenied(binaryPath: String)
    case systemEventsDenied(binaryPath: String, details: String?)
    case systemEventsUnknown(binaryPath: String, details: String?)

    public var description: String {
        switch self {
        case .accessibilityDenied(let binaryPath):
            return "Accessibility permission is not granted for \(binaryPath)"
        case .systemEventsDenied(let binaryPath, let details):
            if let details, !details.isEmpty {
                return "System Events automation is denied for \(binaryPath): \(details)"
            }
            return "System Events automation is denied for \(binaryPath)"
        case .systemEventsUnknown(let binaryPath, let details):
            if let details, !details.isEmpty {
                return "Could not verify System Events automation for \(binaryPath): \(details)"
            }
            return "Could not verify System Events automation for \(binaryPath)"
        }
    }
}

public enum AutomationPermissions {
    public static func currentBinaryPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    public static func report() -> AutomationPermissionReport {
        AutomationPermissionReport(
            binaryPath: currentBinaryPath(),
            accessibilityTrusted: AXIsProcessTrusted(),
            systemEventsAutomation: probeSystemEventsAutomation()
        )
    }

    public static func requireForSend() throws {
        let current = report()
        guard current.accessibilityTrusted else {
            throw AutomationPermissionError.accessibilityDenied(binaryPath: current.binaryPath)
        }
        switch current.systemEventsAutomation {
        case .granted:
            return
        case .denied(let details):
            throw AutomationPermissionError.systemEventsDenied(
                binaryPath: current.binaryPath,
                details: details
            )
        case .unknown(let details):
            throw AutomationPermissionError.systemEventsUnknown(
                binaryPath: current.binaryPath,
                details: details
            )
        }
    }

    private static func probeSystemEventsAutomation() -> AutomationPermissionStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to return name of first application process",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .unknown(error.localizedDescription)
        }

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = "\(out)\n\(err)".trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0 {
            return .granted
        }

        let normalized = combined.lowercased()
        if normalized.contains("-1743") ||
            normalized.contains("not authorized") ||
            normalized.contains("not permitted") ||
            normalized.contains("automation") {
            return .denied(combined.isEmpty ? nil : combined)
        }

        return .unknown(combined.isEmpty ? "osascript exited with status \(process.terminationStatus)" : combined)
    }
}
