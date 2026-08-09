import XCTest
import Foundation
@testable import MeetingNoteTaker

/// Real end-to-end smoke test against whisper.cpp's own bundled sample audio
/// (Vendor/whisper.cpp/samples/jfk.wav) and the downloaded ggml-small.en.bin
/// model. Skips gracefully if either isn't present — both are large binaries
/// that aren't committed to git, so this only runs on a machine that's
/// downloaded them (via Vendor/whisper.cpp/models/download-ggml-model.sh).
final class WhisperTranscriberTests: XCTestCase {
    func testTranscribesKnownSampleAudio() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WhisperTranscriberTests.swift
            .deletingLastPathComponent() // MeetingNoteTakerTests
            .deletingLastPathComponent() // Tests
        let modelPath = packageRoot.appendingPathComponent("Vendor/whisper.cpp/models/ggml-small.en.bin")
        let sampleAudioPath = packageRoot.appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw XCTSkip("ggml-small.en.bin not downloaded — run Vendor/whisper.cpp/models/download-ggml-model.sh small.en")
        }
        guard FileManager.default.fileExists(atPath: sampleAudioPath.path) else {
            throw XCTSkip("Vendor/whisper.cpp/samples/jfk.wav missing from the submodule checkout")
        }

        let transcriber = WhisperTranscriber(modelPath: modelPath)
        // onStatusChange fires from WhisperTranscriber's dedicated background
        // thread (see its doc comment); this test only reads the result
        // after awaiting the call below, so there's no actual concurrent
        // access despite the capture crossing a thread boundary.
        nonisolated(unsafe) var statuses: [TranscriptionStatus] = []
        let text = try await transcriber.transcribe(audioFileURL: sampleAudioPath) { status in
            statuses.append(status)
        }

        // The JFK sample is the famous "ask not what your country can do for
        // you" excerpt. Don't assert exact wording (ASR output varies
        // slightly by model/version) — just that recognizable words came
        // through, proving the whole pipeline (load -> resample -> whisper.cpp
        // -> segment extraction) actually works end to end.
        let lowercased = text.lowercased()
        XCTAssertTrue(lowercased.contains("country"), "Expected the known JFK sample transcript to mention 'country', got: \(text)")
        XCTAssertTrue(statuses.contains { if case .finished = $0 { return true }; return false })
    }
}
