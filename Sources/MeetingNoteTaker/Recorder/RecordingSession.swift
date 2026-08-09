import Foundation

struct RecordingSession {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    let audioFileURL: URL

    static func startNew() throws -> RecordingSession {
        try StorageLocation.prepare()
        let id = UUID()
        let url = StorageLocation.recordingsDirectory.appendingPathComponent("\(id.uuidString).caf")
        return RecordingSession(id: id, startedAt: Date(), endedAt: nil, audioFileURL: url)
    }
}
