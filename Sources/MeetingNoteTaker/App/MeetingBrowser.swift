import Foundation

/// CLI-only browse/list surface for stored meetings. Exists specifically to
/// close a real gap flagged during the Phase 1 hardening pass's outside-voice
/// review: retention silently deletes audio with no way to see what's
/// stored first. Real UI is still deferred to later in Phase 2 — this is
/// just enough to make retention's effects visible from the same CLI.
enum MeetingBrowser {
    /// Meetings are numbered 1..N in the order returned by allMeetings()
    /// (most-recent-first) — friendlier for a human to type than a UUID.
    static func printList(_ meetings: [Meeting], now: Date = Date()) {
        guard !meetings.isEmpty else {
            print("No meetings recorded yet.")
            return
        }
        for (offset, meeting) in meetings.enumerated() {
            print(listLine(index: offset + 1, meeting: meeting, now: now))
        }
        print("\nRun `meetingnotetaker show <number>` for the full transcript and summary.")
    }

    static func printDetail(_ meetings: [Meeting], index: Int, now: Date = Date()) {
        guard let meeting = meetings[safe: index - 1] else {
            print("No meeting #\(index). Run `meetingnotetaker list` to see valid numbers (1-\(meetings.count)).")
            return
        }
        print(detailText(meeting: meeting, now: now))
    }

    // MARK: - Pure formatting (unit-testable without a real MeetingStore)

    static func listLine(index: Int, meeting: Meeting, now: Date = Date()) -> String {
        let date = Self.dateFormatter.string(from: meeting.startedAt)
        let duration = meeting.endedAt.map { durationString(from: meeting.startedAt, to: $0) } ?? "unknown length"
        let audio = audioStatus(meeting: meeting, now: now)
        let transcript = preview(meeting.transcriptText, fallback: "(no transcript yet)")
        let summarySuffix = meeting.summaryText.map { " | summary: \(preview($0, fallback: ""))" } ?? ""
        return "[\(index)] \(date) (\(duration)) — \(audio)\n     \(transcript)\(summarySuffix)"
    }

    static func detailText(meeting: Meeting, now: Date = Date()) -> String {
        let date = Self.dateFormatter.string(from: meeting.startedAt)
        let duration = meeting.endedAt.map { durationString(from: meeting.startedAt, to: $0) } ?? "unknown length"
        var lines = [
            "Date: \(date) (\(duration))",
            "Audio: \(audioStatus(meeting: meeting, now: now))",
            "Audio file: \(meeting.audioFilePath)",
            ""
        ]
        lines.append("Transcript:")
        lines.append(meeting.transcriptText ?? "(no transcript yet)")
        if let summary = meeting.summaryText {
            lines.append("")
            lines.append("Summary:")
            lines.append(summary)
        }
        return lines.joined(separator: "\n")
    }

    static func audioStatus(meeting: Meeting, now: Date) -> String {
        if meeting.audioDeletedAt != nil {
            return "audio deleted"
        }
        guard let retainUntil = meeting.retainUntil else {
            return "audio kept"
        }
        let days = daysUntilExpiry(retainUntil, now: now)
        if days <= 0 {
            return "audio kept (deletion pending — past its retention window)"
        }
        return "audio kept, deletes in \(days)d"
    }

    static func daysUntilExpiry(_ retainUntil: Date, now: Date) -> Int {
        Int(ceil(retainUntil.timeIntervalSince(now) / 86_400))
    }

    static func preview(_ text: String?, fallback: String, maxLength: Int = 80) -> String {
        guard let text else { return fallback }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return fallback }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "…"
    }

    static func durationString(from start: Date, to end: Date) -> String {
        let totalSeconds = max(0, Int(end.timeIntervalSince(start)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
