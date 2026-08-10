import Foundation
import SQLite3

struct Meeting: Identifiable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var audioFilePath: String
    var transcriptText: String?
    /// When the audio file becomes eligible for automatic deletion (7 days
    /// after recording, per the Phase 1 hardening pass retention policy).
    var retainUntil: Date?
    /// When the audio file was actually deleted by deleteExpiredAudio().
    /// audioFilePath is deliberately kept (not nulled out) as a historical
    /// record — this field is the explicit signal callers must check before
    /// assuming the file at audioFilePath still exists.
    var audioDeletedAt: Date?
}

/// Local-only persistence: SQLite for structured metadata + queryable
/// transcript text, flat files under StorageLocation.recordingsDirectory for
/// the raw audio itself. No network access anywhere in this type.
final class MeetingStore {
    private var db: OpaquePointer?

    convenience init() throws {
        try StorageLocation.prepare()
        try self.init(databaseURL: StorageLocation.databaseURL)
    }

    /// Exposed for tests that need to open a specific database file (e.g. a
    /// pre-existing fixture predating a schema migration) rather than the
    /// real on-disk location.
    init(databaseURL: URL) throws {
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            throw StoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try createSchemaIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    enum StoreError: Error {
        case openFailed(String)
        case execFailed(String)
    }

    private func createSchemaIfNeeded() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meetings (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            audio_file_path TEXT NOT NULL,
            transcript_text TEXT,
            retain_until REAL,
            audio_deleted_at REAL
        );
        CREATE INDEX IF NOT EXISTS idx_meetings_started_at ON meetings(started_at);
        CREATE INDEX IF NOT EXISTS idx_meetings_retain_until ON meetings(retain_until);
        """)
        // CREATE TABLE IF NOT EXISTS only creates the full schema on a brand
        // new database — it does nothing to a database that already exists
        // from before audio_deleted_at was added (every Phase 1 install).
        // This migration closes that gap explicitly rather than assuming a
        // fresh install.
        try migrateAddAudioDeletedAtColumnIfNeeded()
    }

    private func migrateAddAudioDeletedAtColumnIfNeeded() throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(meetings);", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        var hasColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let nameCString = sqlite3_column_text(statement, 1),
               String(cString: nameCString) == "audio_deleted_at" {
                hasColumn = true
                break
            }
        }
        guard !hasColumn else { return }
        try exec("ALTER TABLE meetings ADD COLUMN audio_deleted_at REAL;")
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw StoreError.execFailed(message)
        }
    }

    func insert(_ meeting: Meeting) throws {
        let sql = """
        INSERT INTO meetings (id, started_at, ended_at, audio_file_path, transcript_text, retain_until, audio_deleted_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, meeting.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, meeting.startedAt.timeIntervalSince1970)
        bindOptionalDate(statement, 3, meeting.endedAt)
        sqlite3_bind_text(statement, 4, meeting.audioFilePath, -1, SQLITE_TRANSIENT)
        if let transcript = meeting.transcriptText {
            sqlite3_bind_text(statement, 5, transcript, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bindOptionalDate(statement, 6, meeting.retainUntil)
        bindOptionalDate(statement, 7, meeting.audioDeletedAt)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindOptionalDate(_ statement: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date {
            sqlite3_bind_double(statement, index, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func updateTranscript(meetingID: UUID, transcript: String) throws {
        let sql = "UPDATE meetings SET transcript_text = ? WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, transcript, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, meetingID.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func markAudioDeleted(meetingID: UUID, deletedAt: Date) throws {
        let sql = "UPDATE meetings SET audio_deleted_at = ? WHERE id = ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(statement, 1, deletedAt.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, meetingID.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func allMeetings() throws -> [Meeting] {
        let sql = "SELECT id, started_at, ended_at, audio_file_path, transcript_text, retain_until, audio_deleted_at FROM meetings ORDER BY started_at DESC;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }

        var results: [Meeting] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let meeting = meetingFromRow(statement) {
                results.append(meeting)
            }
        }
        return results
    }

    /// Deletes the audio file for every meeting whose retainUntil has
    /// passed and whose audio hasn't already been deleted. Safe to call
    /// repeatedly (idempotent): a meeting already marked audioDeletedAt is
    /// never revisited, and a file already missing on disk (manual deletion,
    /// a prior partial run) doesn't cause a failure — it's still marked
    /// deleted rather than retried forever. Returns the pruned meetings for
    /// logging at the call site.
    @discardableResult
    func deleteExpiredAudio(now: Date = Date()) throws -> [Meeting] {
        let sql = """
        SELECT id, started_at, ended_at, audio_file_path, transcript_text, retain_until, audio_deleted_at
        FROM meetings
        WHERE retain_until IS NOT NULL AND retain_until <= ? AND audio_deleted_at IS NULL;
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)

        var expired: [Meeting] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let meeting = meetingFromRow(statement) {
                expired.append(meeting)
            }
        }

        var pruned: [Meeting] = []
        for var meeting in expired {
            try? FileManager.default.removeItem(atPath: meeting.audioFilePath)
            try markAudioDeleted(meetingID: meeting.id, deletedAt: now)
            meeting.audioDeletedAt = now
            pruned.append(meeting)
        }
        return pruned
    }

    private func meetingFromRow(_ statement: OpaquePointer?) -> Meeting? {
        guard let idCString = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idCString)),
              let audioPathCString = sqlite3_column_text(statement, 3) else {
            return nil
        }
        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let endedAt = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let transcript = sqlite3_column_text(statement, 4).map { String(cString: $0) }
        let retainUntil = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
        let audioDeletedAt = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))

        return Meeting(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            audioFilePath: String(cString: audioPathCString),
            transcriptText: transcript,
            retainUntil: retainUntil,
            audioDeletedAt: audioDeletedAt
        )
    }
}

// sqlite3_bind_text needs an explicit "destructor" constant telling SQLite
// to copy the string rather than assume the caller keeps it alive.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
