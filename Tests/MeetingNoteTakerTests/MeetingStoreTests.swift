import XCTest
import Foundation
import SQLite3
@testable import MeetingNoteTaker

final class MeetingStoreTests: XCTestCase {
    func testInsertAndFetchMeeting() throws {
        let (store, _) = try makeTempMeetingStore()
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
        let (store, _) = try makeTempMeetingStore()
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

    // MARK: - deleteExpiredAudio

    func testDeleteExpiredAudioPrunesExpiredMeeting() throws {
        let (store, _) = try makeTempMeetingStore()
        let audioURL = try makeTempAudioFile()
        let meeting = Meeting(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            audioFilePath: audioURL.path,
            transcriptText: "hello",
            retainUntil: Date().addingTimeInterval(-1), // already expired
            audioDeletedAt: nil
        )
        try store.insert(meeting)

        let pruned = try store.deleteExpiredAudio()

        XCTAssertEqual(pruned.map(\.id), [meeting.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        let updated = try store.allMeetings().first { $0.id == meeting.id }
        XCTAssertNotNil(updated?.audioDeletedAt)
    }

    func testDeleteExpiredAudioLeavesNotYetExpiredMeetingUntouched() throws {
        let (store, _) = try makeTempMeetingStore()
        let audioURL = try makeTempAudioFile()
        let meeting = Meeting(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            audioFilePath: audioURL.path,
            transcriptText: "hello",
            retainUntil: Date().addingTimeInterval(60 * 60 * 24 * 7), // 7 days out
            audioDeletedAt: nil
        )
        try store.insert(meeting)

        let pruned = try store.deleteExpiredAudio()

        XCTAssertTrue(pruned.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDeleteExpiredAudioSkipsAlreadyDeletedMeeting() throws {
        let (store, _) = try makeTempMeetingStore()
        let meeting = Meeting(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            audioFilePath: "/tmp/already-gone-\(UUID().uuidString).caf",
            transcriptText: "hello",
            retainUntil: Date().addingTimeInterval(-1),
            audioDeletedAt: Date().addingTimeInterval(-3600) // deleted an hour ago
        )
        try store.insert(meeting)

        let pruned = try store.deleteExpiredAudio()

        XCTAssertTrue(pruned.isEmpty, "already-deleted meetings must not be revisited")
    }

    func testDeleteExpiredAudioToleratesAlreadyMissingFile() throws {
        let (store, _) = try makeTempMeetingStore()
        let meeting = Meeting(
            id: UUID(),
            startedAt: Date(),
            endedAt: Date(),
            audioFilePath: "/tmp/never-existed-\(UUID().uuidString).caf",
            transcriptText: "hello",
            retainUntil: Date().addingTimeInterval(-1),
            audioDeletedAt: nil
        )
        try store.insert(meeting)

        // Must not throw even though the file was never actually on disk.
        let pruned = try store.deleteExpiredAudio()

        XCTAssertEqual(pruned.map(\.id), [meeting.id])
        let updated = try store.allMeetings().first { $0.id == meeting.id }
        XCTAssertNotNil(updated?.audioDeletedAt)
    }

    // MARK: - Legacy DB migration

    func testOpeningPreExistingPhase1DatabaseMigratesWithoutCrashing() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-meetingstore-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        // Build a fixture matching the original Phase 1 schema (before
        // audio_deleted_at existed) using raw SQLite, independent of
        // MeetingStore itself — this must look like a real pre-migration
        // database on disk, not one MeetingStore already touched.
        var legacyDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &legacyDB), SQLITE_OK)
        let createSQL = """
        CREATE TABLE meetings (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            audio_file_path TEXT NOT NULL,
            transcript_text TEXT,
            retain_until REAL
        );
        """
        XCTAssertEqual(sqlite3_exec(legacyDB, createSQL, nil, nil, nil), SQLITE_OK)
        let legacyID = UUID()
        let insertSQL = "INSERT INTO meetings (id, started_at, audio_file_path) VALUES ('\(legacyID.uuidString)', 0, '/tmp/legacy.caf');"
        XCTAssertEqual(sqlite3_exec(legacyDB, insertSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacyDB)

        // Opening it with the current MeetingStore must not crash, must add
        // the missing column, and must preserve the pre-existing row.
        let store = try MeetingStore(databaseURL: dbURL)
        let all = try store.allMeetings()
        XCTAssertTrue(all.contains { $0.id == legacyID })
        XCTAssertNil(all.first { $0.id == legacyID }?.audioDeletedAt)

        // And the new column must actually be usable now.
        try store.deleteExpiredAudio(now: Date(timeIntervalSince1970: 0))
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
