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

    /// Grace period between recording and audio becoming eligible for
    /// automatic deletion — see TODOS.md "Data retention / deletion policy".
    /// Long enough to notice and re-run a bad transcription against the
    /// source audio before it's gone.
    private static let audioRetentionGracePeriod: TimeInterval = 7 * 24 * 60 * 60

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

        // FileVault is the accepted v1 data-at-rest boundary (see TODOS.md
        // "Encryption at rest") — warn, don't block, matching the same
        // accepted-risk posture already used for the iCloud-exclusion
        // mitigation in StorageLocation.
        if !StorageLocation.isFileVaultEnabled() {
            print("""

            ────────────────────────────────────────────────────────────
            Warning: FileVault is not enabled. This app relies on
            FileVault as its only data-at-rest protection (see TODOS.md
            "Encryption at rest") — without it, meeting recordings and
            transcripts are stored unencrypted on disk. Enable it in
            System Settings > Privacy & Security > FileVault.
            ────────────────────────────────────────────────────────────
            """)
        }

        let store = try MeetingStore()
        let pruned = try store.deleteExpiredAudio()
        if !pruned.isEmpty {
            print("Deleted \(pruned.count) audio file(s) past the \(Int(audioRetentionGracePeriod / 86_400))-day retention window (transcripts kept).")
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

        // Insert the Meeting row immediately, before attempting
        // transcription — not after. Audio that fails to transcribe (e.g.
        // no model found) used to get no DB row at all, which meant no
        // retainUntil and permanent exemption from the retention policy
        // above: exactly the audio most likely to sit around unreviewed.
        // retainUntil is anchored to the recording, not to a successful
        // transcript, so it applies uniformly either way.
        let meeting = Meeting(
            id: session.id,
            startedAt: finishedSession.startedAt,
            endedAt: finishedSession.endedAt,
            audioFilePath: finishedSession.audioFileURL.path,
            transcriptText: nil,
            retainUntil: finishedSession.startedAt.addingTimeInterval(audioRetentionGracePeriod),
            audioDeletedAt: nil
        )
        try store.insert(meeting)

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

        try store.updateTranscript(meetingID: meeting.id, transcript: transcript)
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
