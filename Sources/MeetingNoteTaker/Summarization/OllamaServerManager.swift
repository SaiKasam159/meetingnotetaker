import Foundation

/// Whether ensureRunning() started and controls the server (cloud inference
/// guaranteed disabled) or found one already running that it can't vouch for.
enum OllamaServerStatus: Equatable {
    case launchedManaged
    case reusedExisting
}

/// Launches and supervises a local `ollama serve` process with cloud
/// inference hard-disabled, rather than relying on Ollama.app being launched
/// separately (which wouldn't have OLLAMA_NO_CLOUD set). Ollama added an
/// optional cloud-inference feature that routes some models to ollama.com —
/// directly at odds with this project's local-only premise, so this is
/// disabled at the process-launch level, not just by avoiding cloud-tagged
/// model names.
final class OllamaServerManager {
    enum ServerError: Error {
        case binaryNotFound
        case launchFailed(String)
        case didNotBecomeReady
    }

    /// Checked in order; the Ollama.app bundle path is what a plain
    /// drag-to-Applications install produces (no Homebrew dependency,
    /// verified working on the original dev machine). /usr/local/bin/ollama
    /// covers a Homebrew install or a machine where the CLI symlink was set
    /// up via Ollama.app's own "install CLI" prompt.
    private static let binaryCandidates = [
        "/Applications/Ollama.app/Contents/Resources/ollama",
        "/usr/local/bin/ollama"
    ]

    private static let versionURL = URL(string: "http://127.0.0.1:11434/api/version")!

    private var process: Process?

    /// Pure, testable: picks the first existing candidate path. Split out
    /// from the real filesystem check so path-selection logic has direct
    /// test coverage.
    static func resolveBinaryPath(candidates: [String] = binaryCandidates, fileExists: (String) -> Bool) -> String? {
        candidates.first(where: fileExists)
    }

    /// Pure, testable: overrides OLLAMA_NO_CLOUD in a base environment,
    /// regardless of what the base already contains. Split out from Process
    /// setup so the override logic has direct test coverage.
    static func managedEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env["OLLAMA_NO_CLOUD"] = "true"
        return env
    }

    /// Ensures a local Ollama server is reachable, launching a
    /// cloud-disabled one if none is running yet. If a server is already
    /// listening on 11434 (e.g. Ollama.app launched normally via Finder),
    /// this does NOT attempt to replace it — there's no way to verify
    /// whether that server has cloud disabled, so callers must treat
    /// .reusedExisting as unverified and warn accordingly, per the
    /// "warn, don't silently assume" pattern used for FileVault.
    func ensureRunning() async throws -> OllamaServerStatus {
        if await isReachable() {
            return .reusedExisting
        }

        guard let binaryPath = Self.resolveBinaryPath(fileExists: { FileManager.default.fileExists(atPath: $0) }) else {
            throw ServerError.binaryNotFound
        }

        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: binaryPath)
        launched.arguments = ["serve"]
        launched.environment = Self.managedEnvironment(base: ProcessInfo.processInfo.environment)
        launched.standardOutput = FileHandle.nullDevice
        launched.standardError = FileHandle.nullDevice

        do {
            try launched.run()
        } catch {
            throw ServerError.launchFailed(error.localizedDescription)
        }
        process = launched

        for _ in 0..<20 {
            if await isReachable() { return .launchedManaged }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ServerError.didNotBecomeReady
    }

    private func isReachable() async -> Bool {
        var request = URLRequest(url: Self.versionURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
