import SwiftUI
import Foundation
import CryptoKit

/// Reads and writes Claude Code's global config files in its config dir
/// (~/.claude, or $CLAUDE_CONFIG_DIR when set)
@MainActor
class ClaudeConfigManager: ObservableObject {
    @Published var claudeMdText: String = ""
    @Published var cleanupPeriodDays: String = ""
    @Published var statusMessage: String?
    @Published var loadError: String?

    // Resolve the real home directory (works even if the app is ever sandboxed)
    static let homeDir: URL = {
        let home: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home)
    }()

    /// CLAUDE_CONFIG_DIR exactly as Claude Code sees it, or nil when unset.
    /// Apps launched from Finder or at login don't inherit shell variables, so
    /// fall back to the launchd user environment (`launchctl setenv`).
    static let configDirOverride: String? = {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return dir
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "CLAUDE_CONFIG_DIR"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let dir = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return dir.isEmpty ? nil : dir
    }()

    static let claudeDir: URL = {
        guard let dir = configDirOverride else {
            return homeDir.appendingPathComponent(".claude")
        }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
    }()

    /// The config dir for display, eg "~/.claude"
    static let claudeDirDisplay: String = {
        let path = claudeDir.path
        let home = homeDir.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }()

    /// Keychain services that may hold Claude Code's OAuth credentials, best first.
    /// With CLAUDE_CONFIG_DIR set, Claude Code suffixes the service with the
    /// first 8 hex digits of the SHA-256 of that value, so each config dir keeps
    /// its own login.
    static let keychainServices: [String] = {
        let base = "Claude Code-credentials"
        guard let dir = configDirOverride else { return [base] }
        let digest = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["\(base)-\(digest.prefix(8))", base]
    }()

    var claudeMdURL: URL { Self.claudeDir.appendingPathComponent("CLAUDE.md") }
    var settingsJsonURL: URL { Self.claudeDir.appendingPathComponent("settings.json") }

    func load() {
        loadError = nil
        statusMessage = nil

        claudeMdText = (try? String(contentsOf: claudeMdURL, encoding: .utf8)) ?? ""

        if let data = try? Data(contentsOf: settingsJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let days = (json["cleanupPeriodDays"] as? NSNumber)?.intValue {
                cleanupPeriodDays = String(days)
            } else {
                cleanupPeriodDays = ""
            }
        } else if FileManager.default.fileExists(atPath: settingsJsonURL.path) {
            loadError = "Could not parse settings.json"
        } else {
            cleanupPeriodDays = ""
        }
    }

    func saveClaudeMd() {
        do {
            try FileManager.default.createDirectory(at: Self.claudeDir, withIntermediateDirectories: true)
            try claudeMdText.write(to: claudeMdURL.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
            statusMessage = "Saved CLAUDE.md"
        } catch {
            statusMessage = "Failed to save CLAUDE.md: \(error.localizedDescription)"
        }
    }

    /// Updates only cleanupPeriodDays, preserving every other key in settings.json
    func saveCleanupPeriod() {
        let trimmed = cleanupPeriodDays.trimmingCharacters(in: .whitespaces)

        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsJsonURL) {
            guard let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                statusMessage = "settings.json is not valid JSON — not overwriting it"
                return
            }
            json = existing
        }

        if trimmed.isEmpty {
            json.removeValue(forKey: "cleanupPeriodDays")
        } else if let days = Int(trimmed), days > 0 {
            json["cleanupPeriodDays"] = days
        } else {
            statusMessage = "Retention must be a positive number of days"
            return
        }

        do {
            try FileManager.default.createDirectory(at: Self.claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsJsonURL.resolvingSymlinksInPath(), options: .atomic)
            statusMessage = trimmed.isEmpty ? "Retention reset to Claude Code default (30 days)" : "Saved: keep conversations \(trimmed) days"
        } catch {
            statusMessage = "Failed to save settings.json: \(error.localizedDescription)"
        }
    }
}
