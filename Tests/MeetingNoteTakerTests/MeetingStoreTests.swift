import XCTest
import Foundation
@testable import MeetingNoteTaker

final class MeetingStoreTests: XCTestCase {
    func testInsertAndFetchMeeting() throws {
        let store = try MeetingStore()
        let meeting = Meeting(
            id: UUID(),
            startedAt: Date(),
            endedAt: nil,
            audioFilePath: "/tmp/test.caf",
            transcriptText: nil,
            retainUntil: nil
        )
        try store.insert(meeting)

        let all = try store.allMeetings()
        XCTAssertTrue(all.contains { $0.id == meeting.id })
    }

    func testUpdateTranscriptPersists() throws {
        let store = try MeetingStore()
        let meeting = Meeting(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            audioFilePath: "/tmp/test2.caf",
            transcriptText: nil,
            retainUntil: nil
        )
        try store.insert(meeting)
        try store.updateTranscript(meetingID: meeting.id, transcript: "hello world")

        let updated = try store.allMeetings().first { $0.id == meeting.id }
        XCTAssertEqual(updated?.transcriptText, "hello world")
    }
}

final class RecordingRecoveryTests: XCTestCase {
    func testDetectsNoOrphanWhenMarkerAbsent() throws {
        let recovery = RecordingRecovery()
        if let existing = recovery.detectOrphanedRecording() {
            try recovery.discard(existing, deleteAudioFile: true)
        }
        XCTAssertNil(recovery.detectOrphanedRecording())
    }

    func testDetectsOrphanAfterMarkWithoutFinish() throws {
        let recovery = RecordingRecovery()
        let session = try RecordingSession.startNew()
        try recovery.markInProgress(session)

        let orphan = recovery.detectOrphanedRecording()
        XCTAssertEqual(orphan?.sessionID, session.id)

        if let orphan {
            try recovery.discard(orphan, deleteAudioFile: true)
        }
    }
}
