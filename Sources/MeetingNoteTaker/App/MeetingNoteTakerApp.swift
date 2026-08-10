import Foundation

/// Entry point. Wires Recorder -> Transcriber -> Storage as a simple
/// sequential pipeline (eng review decision: no actor/queue system for
/// Phase 1 — this isn't a live/concurrent-recording product yet).
///
/// Phase 1 proof-of-concept only: a plain CLI (press Enter to start/stop),
/// not the real app UI. Confirms the whole pipeline actually works end to
/// end against a real recording before any UI work is justified.
@main
struct MeetingNoteTakerApp {
    /// TEMPORARY: Phase 1 proof-of-concept location for the ggml model —
    /// reuses the model already downloaded into the vendored submodule
    /// rather than duplicating it. Real model bundling/download UX (does the
    /// app ship a model, or download one on first run, and where does it
    /// live in the shipped app vs. this dev checkout) is a deferred decision,
    /// not made here.
    private static var modelPath: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MeetingNoteTakerApp.swift
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // MeetingNoteTaker
            .deletingLastPathComponent() // Sources
            .appendingPathComponent("Vendor/whisper.cpp/models/ggml-small.en.bin")
    }

    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write("Fatal: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func run() async throws {
        let recovery = RecordingRecovery()
        if let orphan = recovery.detectOrphanedRecording() {
            handleOrphanedRecording(orphan, recovery: recovery)
        }

        let micStatus = PermissionManager.checkMicrophonePermission()
        if micStatus == .notDetermined {
            _ = await PermissionManager.requestMicrophonePermission()
        }
        guard PermissionManager.checkMicrophonePermission() == .granted else {
            print("Microphone permission denied. Grant it in System Settings > Privacy & Security > Microphone, then relaunch.")
            return
        }

        let systemAudioStatus = await PermissionManager.checkSystemAudioPermission()
        guard systemAudioStatus == .granted else {
            print("System audio recording permission is required. Opening System Settings...")
            PermissionManager.openScreenRecordingSettings()
            print("Grant \"Screen & System Audio Recording\" access, then relaunch.")
            return
        }

        // Per TODOS.md "Remote-participant consent notification": automated
        // notification is deferred, but a manual verbal announcement is
        // required starting with the first real-meeting test. This isn't
        // skippable UX — it's printed every run as a standing reminder,
        // not a one-time onboarding tip.
        print("""

        ────────────────────────────────────────────────────────────
        Reminder: if anyone else is on this call, tell them out loud
        that you're recording before you start. Automated in-meeting
        notification isn't built yet (see TODOS.md) — this is on you
        until it is.
        ────────────────────────────────────────────────────────────

        Press Enter to start recording, then Enter again to stop.
        """)
        _ = readLine()

        let recorder = AudioRecorder()
        let session = try await recorder.startRecording()
        print("Recording... (session \(session.id))")
        print("Press Enter to stop.")
        _ = readLine()

        let finishedSession = try await recorder.stopRecording()
        print("Stopped. Audio saved to \(finishedSession.audioFileURL.path)")

        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            print("No Whisper model found at \(modelPath.path) — skipping transcription. Audio is saved; run transcription later once a model is available.")
            return
        }

        print("Transcribing (this runs entirely locally, no network calls)...")
        let transcriber = WhisperTranscriber(modelPath: modelPath)
        let transcript = try await transcriber.transcribe(audioFileURL: finishedSession.audioFileURL) { status in
            switch status {
            case .transcribing(let progress):
                let percent = Int(progress * 100)
                FileHandle.standardError.write("\rTranscribing... \(percent)%".data(using: .utf8)!)
            default:
                break
            }
        }
        print("\nTranscript:\n\(transcript)")

        let store = try MeetingStore()
        let meeting = Meeting(
            id: session.id,
            startedAt: finishedSession.startedAt,
            endedAt: finishedSession.endedAt,
            audioFilePath: finishedSession.audioFileURL.path,
            transcriptText: transcript,
            retainUntil: nil
        )
        try store.insert(meeting)
        print("Saved to local store: \(StorageLocation.databaseURL.path)")
    }

    /// Reminder per TODOS.md: consent notification automation is deferred,
    /// but a manual verbal announcement is required starting with the first
    /// real-meeting test — this recovery path existing at all is a signal
    /// that a real recording happened, so it's a fitting place to reiterate
    /// that expectation for whoever is running this.
    private static func handleOrphanedRecording(_ orphan: OrphanedRecording, recovery: RecordingRecovery) {
        if orphan.hasRecoverableAudio {
            print("Recovered an in-progress recording from \(orphan.startedAt) that didn't finish cleanly.")
            print("Partial audio kept at: \(orphan.audioFileURL.path)")
            try? recovery.discard(orphan, deleteAudioFile: false)
        } else {
            print("Found an empty in-progress recording marker from \(orphan.startedAt) — discarding, no audio was captured.")
            try? recovery.discard(orphan, deleteAudioFile: true)
        }
    }
}
