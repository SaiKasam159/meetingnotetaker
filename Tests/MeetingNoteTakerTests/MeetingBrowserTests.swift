import XCTest
@testable import MeetingNoteTaker

final class MeetingBrowserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func makeMeeting(
        retainUntil: Date? = nil,
        audioDeletedAt: Date? = nil,
        transcriptText: String? = nil,
        summaryText: String? = nil,
        endedAt: Date? = nil
    ) -> Meeting {
        Meeting(
            id: UUID(),
            startedAt: now.addingTimeInterval(-90),
            endedAt: endedAt,
            audioFilePath: "/tmp/x.caf",
            transcriptText: transcriptText,
            retainUntil: retainUntil,
            audioDeletedAt: audioDeletedAt,
            summaryText: summaryText
        )
    }

    // MARK: - audioStatus

    func testAudioStatusDeleted() {
        let meeting = makeMeeting(retainUntil: now.addingTimeInterval(100), audioDeletedAt: now)
        XCTAssertEqual(MeetingBrowser.audioStatus(meeting: meeting, now: now), "audio deleted")
    }

    func testAudioStatusKeptWithDaysRemaining() {
        let meeting = makeMeeting(retainUntil: now.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(MeetingBrowser.audioStatus(meeting: meeting, now: now), "audio kept, deletes in 2d")
    }

    func testAudioStatusPastRetentionButNotYetPruned() {
        let meeting = makeMeeting(retainUntil: now.addingTimeInterval(-100))
        XCTAssertEqual(MeetingBrowser.audioStatus(meeting: meeting, now: now), "audio kept (deletion pending — past its retention window)")
    }

    func testAudioStatusNoRetentionSet() {
        let meeting = makeMeeting(retainUntil: nil)
        XCTAssertEqual(MeetingBrowser.audioStatus(meeting: meeting, now: now), "audio kept")
    }

    // MARK: - preview

    func testPreviewReturnsFallbackForNil() {
        XCTAssertEqual(MeetingBrowser.preview(nil, fallback: "(none)"), "(none)")
    }

    func testPreviewReturnsFallbackForEmptyOrWhitespace() {
        XCTAssertEqual(MeetingBrowser.preview("   \n  ", fallback: "(none)"), "(none)")
    }

    func testPreviewCollapsesNewlinesAndTrims() {
        XCTAssertEqual(MeetingBrowser.preview("line one\nline two  ", fallback: "(none)"), "line one line two")
    }

    func testPreviewTruncatesLongText() {
        let long = String(repeating: "a", count: 200)
        let result = MeetingBrowser.preview(long, fallback: "(none)", maxLength: 10)
        XCTAssertEqual(result, String(repeating: "a", count: 10) + "…")
    }

    // MARK: - durationString

    func testDurationStringFormatsMinutesAndSeconds() {
        let start = now
        let end = now.addingTimeInterval(125) // 2:05
        XCTAssertEqual(MeetingBrowser.durationString(from: start, to: end), "2:05")
    }

    func testDurationStringClampsNegativeToZero() {
        let start = now
        let end = now.addingTimeInterval(-10)
        XCTAssertEqual(MeetingBrowser.durationString(from: start, to: end), "0:00")
    }

    // MARK: - printDetail bounds checking (index out of range shouldn't crash)

    func testPrintDetailOutOfRangeDoesNotCrash() {
        MeetingBrowser.printDetail([], index: 1)
        MeetingBrowser.printDetail([makeMeeting()], index: 0)
        MeetingBrowser.printDetail([makeMeeting()], index: 2)
        // No assertion beyond "did not crash" — this is a bounds-safety test.
    }

    func testDaysUntilExpiryRoundsUp() {
        // 1.5 days out should read as 2 days remaining, not 1 (round up so
        // "expires in 0d" only appears once it's truly imminent/past).
        let retainUntil = now.addingTimeInterval(1.5 * 86_400)
        XCTAssertEqual(MeetingBrowser.daysUntilExpiry(retainUntil, now: now), 2)
    }
}
