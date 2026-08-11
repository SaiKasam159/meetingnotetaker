import XCTest
@testable import MeetingNoteTaker

final class OllamaServerManagerTests: XCTestCase {
    // MARK: - resolveBinaryPath

    func testResolveBinaryPathPicksFirstExistingCandidate() {
        let candidates = ["/does/not/exist", "/Applications/Ollama.app/Contents/Resources/ollama", "/usr/local/bin/ollama"]
        let resolved = OllamaServerManager.resolveBinaryPath(candidates: candidates) { path in
            path == "/Applications/Ollama.app/Contents/Resources/ollama"
        }
        XCTAssertEqual(resolved, "/Applications/Ollama.app/Contents/Resources/ollama")
    }

    func testResolveBinaryPathFallsBackToLaterCandidate() {
        let candidates = ["/Applications/Ollama.app/Contents/Resources/ollama", "/usr/local/bin/ollama"]
        let resolved = OllamaServerManager.resolveBinaryPath(candidates: candidates) { path in
            path == "/usr/local/bin/ollama"
        }
        XCTAssertEqual(resolved, "/usr/local/bin/ollama")
    }

    func testResolveBinaryPathReturnsNilWhenNoneExist() {
        let candidates = ["/does/not/exist", "/also/not/here"]
        let resolved = OllamaServerManager.resolveBinaryPath(candidates: candidates) { _ in false }
        XCTAssertNil(resolved)
    }

    // MARK: - managedEnvironment

    func testManagedEnvironmentSetsCloudDisabled() {
        let env = OllamaServerManager.managedEnvironment(base: ["PATH": "/usr/bin"])
        XCTAssertEqual(env["OLLAMA_NO_CLOUD"], "true")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testManagedEnvironmentOverridesExistingCloudSetting() {
        // Even if something in the base environment already set this to
        // false, our managed launch must force it back to true — this is
        // the whole point of the app owning the server lifecycle.
        let env = OllamaServerManager.managedEnvironment(base: ["OLLAMA_NO_CLOUD": "false"])
        XCTAssertEqual(env["OLLAMA_NO_CLOUD"], "true")
    }
}
