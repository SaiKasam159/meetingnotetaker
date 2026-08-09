import Foundation

enum TranscriptionStatus: @unchecked Sendable {
    case idle
    case transcribing(progress: Double)
    case finished(String)
    case failed(Error)
}

protocol Transcribing {
    /// Transcribes the given audio file, running on a background thread —
    /// per the eng review decision, transcription must never block the UI.
    /// `onStatusChange` is called on an arbitrary background queue; callers
    /// are responsible for hopping to the main actor before touching UI state.
    func transcribe(audioFileURL: URL, onStatusChange: @escaping @Sendable (TranscriptionStatus) -> Void) async throws -> String
}

enum TranscriberError: Error {
    case audioFileMissing
    case audioFileEmpty
    case timedOut
    case underlyingEngineFailure(String)
}
