import XCTest
import MCP
@testable import MeetingNoteTaker

final class MCPServerTests: XCTestCase {
    private func insert(_ store: MeetingStore, transcript: String?, summary: String? = nil, startedAt: Date = Date()) throws -> Meeting {
        let meeting = Meeting(
            id: UUID(),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            audioFilePath: "/tmp/mcp-test.caf",
            transcriptText: transcript,
            retainUntil: nil,
            audioDeletedAt: nil,
            summaryText: summary
        )
        try store.insert(meeting)
        return meeting
    }

    // MARK: - meetingIndex parsing

    func testMeetingIndexParsesIntValue() {
        XCTAssertEqual(MCPServer.meetingIndex(from: ["meetingIndex": .int(3)]), 3)
    }

    func testMeetingIndexNilWhenMissing() {
        XCTAssertNil(MCPServer.meetingIndex(from: [:]))
        XCTAssertNil(MCPServer.meetingIndex(from: nil))
    }

    func testMeetingIndexNilWhenWrongType() {
        XCTAssertNil(MCPServer.meetingIndex(from: ["meetingIndex": .string("3")]))
    }

    // MARK: - searchMeetings

    func testSearchMeetingsWithNoQueryListsAll() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "roadmap discussion")
        try insert(store, transcript: "budget review")

        let result = try MCPServer.searchMeetings(query: nil, store: store)

        XCTAssertTrue(result.contains("roadmap discussion"))
        XCTAssertTrue(result.contains("budget review"))
    }

    func testSearchMeetingsFiltersByTranscript() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "we discussed the Q3 roadmap")
        try insert(store, transcript: "budget review with finance")

        let result = try MCPServer.searchMeetings(query: "roadmap", store: store)

        XCTAssertTrue(result.contains("roadmap"))
        XCTAssertFalse(result.contains("budget review"))
    }

    func testSearchMeetingsFiltersBySummaryToo() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "long transcript text", summary: "key decision: ship on Friday")
        try insert(store, transcript: "unrelated transcript", summary: "nothing notable")

        let result = try MCPServer.searchMeetings(query: "ship on friday", store: store)

        XCTAssertTrue(result.contains("key decision"))
        XCTAssertFalse(result.contains("nothing notable"))
    }

    func testSearchMeetingsIsCaseInsensitive() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "The Roadmap Discussion")

        let result = try MCPServer.searchMeetings(query: "roadmap", store: store)
        XCTAssertTrue(result.contains("Roadmap"))
    }

    func testSearchMeetingsNoMatchMessage() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "hello")

        let result = try MCPServer.searchMeetings(query: "nonexistent", store: store)
        XCTAssertEqual(result, "No meetings match \"nonexistent\".")
    }

    func testSearchMeetingsEmptyStoreMessage() throws {
        let (store, _) = try makeTempMeetingStore()
        let result = try MCPServer.searchMeetings(query: nil, store: store)
        XCTAssertEqual(result, "No meetings recorded yet.")
    }

    // MARK: - transcript / summary lookup

    func testTranscriptReturnsFullTextAtIndex() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "full transcript body here")

        let result = try MCPServer.transcript(at: 1, store: store)
        XCTAssertEqual(result, "full transcript body here")
    }

    func testTranscriptMissingReturnsPlaceholder() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: nil)

        let result = try MCPServer.transcript(at: 1, store: store)
        XCTAssertEqual(result, "No transcript yet for this meeting.")
    }

    func testTranscriptOutOfRangeReturnsMessage() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "hello")

        let result = try MCPServer.transcript(at: 5, store: store)
        XCTAssertEqual(result, "No meeting #5. Valid range: 1-1.")
    }

    func testSummaryReturnsFullTextAtIndex() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "x", summary: "the summary")

        let result = try MCPServer.summary(at: 1, store: store)
        XCTAssertEqual(result, "the summary")
    }

    func testSummaryMissingReturnsPlaceholder() throws {
        let (store, _) = try makeTempMeetingStore()
        try insert(store, transcript: "x", summary: nil)

        let result = try MCPServer.summary(at: 1, store: store)
        XCTAssertEqual(result, "No summary yet for this meeting (Ollama may not have been available when it was recorded).")
    }
}
