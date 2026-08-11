import XCTest
import Foundation
@testable import MeetingNoteTaker

/// Shared test helpers. MeetingStoreTests learned the hard way that
/// `try MeetingStore()` opens the real on-disk database — every test that
/// inserts data should use makeTempMeetingStore() instead.
extension XCTestCase {
    func makeTempMeetingStore() throws -> (MeetingStore, URL) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetingstore-test-\(UUID().uuidString).sqlite3")
        return (try MeetingStore(databaseURL: dbURL), dbURL)
    }

    func makeTempAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-test-\(UUID().uuidString).caf")
        try Data("fake audio".utf8).write(to: url)
        return url
    }
}
