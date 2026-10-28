import Foundation
import AppKit

/// Downloads a release zip from GitHub, verifies its Developer ID signature,
/// swaps the app bundle in place, and relaunches. No Sparkle dependency.
@MainActor
class UpdateInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading
        case installing
        case relaunching
        case failed(String)
    }

    @Published var state: State = .idle

    static let expectedTeamID = "DFL38M27U3"

    func installUpdate(from url: URL) async {
        guard state == .idle || isFailed else { return }
        state = .downloading

        do {
            let (tmpZip, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.downloadFailed
            }

            state = .installing
            let fm = FileManager.default
            let workDir = fm.temporaryDirectory.appendingPathComponent("ClaudeUsageUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: workDir) }

            try Self.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, workDir.path])
            let newApp = workDir.appendingPathComponent("ClaudeUsage.app")
            guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.badArchive }

            // Refuse anything not signed by us
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            let signInfo = try Self.runCapturingStderr("/usr/bin/codesign", ["-dv", newApp.path])
            guard signInfo.contains("TeamIdentifier=\(Self.expectedTeamID)") else {
                throw UpdateError.wrongSigner
            }

            // Swap: move the running bundle aside, move the new one in, roll back on failure
            let currentURL = Bundle.main.bundleURL
            guard currentURL.lastPathComponent == "ClaudeUsage.app" else {
                throw UpdateError.unexpectedLocation
            }
            let backup = fm.temporaryDirectory.appendingPathComponent("ClaudeUsage-old-\(UUID().uuidString).app")
            try fm.moveItem(at: currentURL, to: backup)
            do {
                try fm.moveItem(at: newApp, to: currentURL)
            } catch {
                try? fm.moveItem(at: backup, to: currentURL)
                throw error
            }
            try? fm.removeItem(at: backup)

            state = .relaunching
            relaunch(at: currentURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func relaunch(at appURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appURL.path)\""]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed(path)
        }
        return process.terminationStatus
    }

    /// codesign -dv prints its details to stderr
    private static func runCapturingStderr(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum UpdateError: LocalizedError {
    case downloadFailed
    case badArchive
    case wrongSigner
    case unexpectedLocation
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Download failed"
        case .badArchive: return "Update archive did not contain ClaudeUsage.app"
        case .wrongSigner: return "Update is not signed by the expected developer"
        case .unexpectedLocation: return "App is running from an unexpected location"
        case .commandFailed(let cmd): return "Update step failed (\(URL(fileURLWithPath: cmd).lastPathComponent))"
        }
    }
}
