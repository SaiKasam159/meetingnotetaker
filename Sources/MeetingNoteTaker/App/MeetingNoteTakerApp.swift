import Foundation

/// Entry point. Wires Recorder -> Transcriber -> Storage as a simple
/// sequential pipeline (eng review decision: no actor/queue system for
/// Phase 1 — this isn't a live/concurrent-recording product yet).
@main
struct MeetingNoteTakerApp {
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

        let systemAudioStatus = await PermissionManager.checkSystemAudioPermission()
        guard systemAudioStatus == .granted else {
            print("System audio recording permission is required. Opening System Settings...")
            PermissionManager.openScreenRecordingSettings()
            print("Grant \"Screen & System Audio Recording\" access, then relaunch.")
            return
        }

        print("MeetingNoteTaker Phase 1 scaffold ready.")
        print("Recorder, Transcriber (pending whisper.cpp wiring), and Storage modules are in place.")
        print("Next: wire a CLI or UI entry point that calls AudioRecorder.startRecording()/stopRecording().")
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
