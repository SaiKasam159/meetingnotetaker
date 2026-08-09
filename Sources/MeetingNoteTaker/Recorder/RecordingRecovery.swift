import Foundation

/// Tracks in-progress recordings via a JSON sidecar marker file so a crash,
/// force-quit, or system restart mid-recording is detectable and recoverable
/// on next launch, rather than leaving a silently corrupt or orphaned file.
///
/// The .caf audio format itself is safe to interrupt mid-write: AVAudioFile
/// flushes frames as they're written, so a partial file is valid and playable
/// up to whatever was captured before the crash. The marker file's job is
/// purely to distinguish "this recording finished normally" from "this
/// recording was still in progress when something went wrong."
struct RecordingRecovery {
    private struct Marker: Codable {
        let sessionID: UUID
        let audioFilePath: String
        let startedAt: Date
    }

    private var markerURL: URL {
        StorageLocation.recordingsDirectory.appendingPathComponent(".inprogress.json")
    }

    func markInProgress(_ session: RecordingSession) throws {
        let marker = Marker(sessionID: session.id, audioFilePath: session.audioFileURL.path, startedAt: session.startedAt)
        let data = try JSONEncoder().encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }

    func markFinished(_ session: RecordingSession) throws {
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }
    }

    /// Call once at app launch, before starting any new recording. If a
    /// marker exists, the previous run ended without calling markFinished —
    /// i.e. a crash or force-quit. Returns the orphaned session info so the
    /// caller can decide whether to salvage (keep the partial audio, attempt
    /// transcription of what exists) or discard it.
    func detectOrphanedRecording() -> OrphanedRecording? {
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else {
            return nil
        }

        let audioURL = URL(fileURLWithPath: marker.audioFilePath)
        let hasAudioData = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int).flatMap { $0 } ?? 0 > 0

        return OrphanedRecording(
            sessionID: marker.sessionID,
            audioFileURL: audioURL,
            startedAt: marker.startedAt,
            hasRecoverableAudio: hasAudioData
        )
    }

    /// Discards an orphaned recording's marker and, if requested, its
    /// partial audio file too.
    func discard(_ orphan: OrphanedRecording, deleteAudioFile: Bool) throws {
        if deleteAudioFile, FileManager.default.fileExists(atPath: orphan.audioFileURL.path) {
            try FileManager.default.removeItem(at: orphan.audioFileURL)
        }
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }
    }
}

struct OrphanedRecording {
    let sessionID: UUID
    let audioFileURL: URL
    let startedAt: Date
    let hasRecoverableAudio: Bool
}
