import Foundation
import SQLite3

struct Meeting: Identifiable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var audioFilePath: String
    var transcriptText: String?
    /// Retention policy is an open TODO (see TODOS.md) — this field exists so
    /// the schema doesn't need a migration once a policy is decided.
    var retainUntil: Date?
}

/// Local-only persistence: SQLite for structured metadata + queryable
/// transcript text, flat files under StorageLocation.recordingsDirectory for
/// the raw audio itself. No network access anywhere in this type.
final class MeetingStore {
    private var db: OpaquePointer?

    init() throws {
        try StorageLocation.prepare()
        let path = StorageLocation.databaseURL.path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
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
        let sql = """
        CREATE TABLE IF NOT EXISTS meetings (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            ended_at REAL,
            audio_file_path TEXT NOT NULL,
            transcript_text TEXT,
            retain_until REAL
        );
        CREATE INDEX IF NOT EXISTS idx_meetings_started_at ON meetings(started_at);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw StoreError.execFailed(message)
        }
    }

    func insert(_ meeting: Meeting) throws {
        let sql = """
        INSERT INTO meetings (id, started_at, ended_at, audio_file_path, transcript_text, retain_until)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, meeting.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, meeting.startedAt.timeIntervalSince1970)
        if let endedAt = meeting.endedAt {
            sqlite3_bind_double(statement, 3, endedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_text(statement, 4, meeting.audioFilePath, -1, SQLITE_TRANSIENT)
        if let transcript = meeting.transcriptText {
            sqlite3_bind_text(statement, 5, transcript, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        if let retainUntil = meeting.retainUntil {
            sqlite3_bind_double(statement, 6, retainUntil.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 6)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
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

    func allMeetings() throws -> [Meeting] {
        let sql = "SELECT id, started_at, ended_at, audio_file_path, transcript_text, retain_until FROM meetings ORDER BY started_at DESC;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }

        var results: [Meeting] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idCString = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idCString)),
                  let audioPathCString = sqlite3_column_text(statement, 3) else {
                continue
            }
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let endedAt = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let transcript = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let retainUntil = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))

            results.append(Meeting(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                audioFilePath: String(cString: audioPathCString),
                transcriptText: transcript,
                retainUntil: retainUntil
            ))
        }
        return results
    }
}

// sqlite3_bind_text needs an explicit "destructor" constant telling SQLite
// to copy the string rather than assume the caller keeps it alive.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
