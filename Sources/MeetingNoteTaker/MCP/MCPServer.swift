import Foundation
import MCP

/// Exposes stored meetings to MCP clients (Claude Desktop, Claude Code) via
/// stdio — launched as a subprocess by the client itself, per Claude's
/// documented local-server integration model. See TODOS.md "MCP server auth
/// model" for why this replaced an earlier Unix-domain-socket design: Claude
/// only supports stdio for local servers, and a subprocess's own stdio pipes
/// aren't reachable by any other local process at all, which is a stronger
/// guarantee than a permission-scoped socket file.
///
/// get_action_items is deliberately NOT exposed yet — action-item extraction
/// doesn't exist (gated on the speaker-diarization decision, see TODOS.md
/// "Speaker diarization"). Only reads the same local MeetingStore the
/// recording pipeline writes to; no network access.
enum MCPServer {
    static func run() async throws {
        let store = try MeetingStore()

        let server = Server(
            name: "meetingnotetaker",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.handleCallTool(params: params, store: store)
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)

        // Claude owns this subprocess's lifecycle (spawns it, kills it when
        // done) — nothing else to wait on.
        try await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
    }

    static let tools: [Tool] = [
        Tool(
            name: "search_meetings",
            description: "Search stored meeting transcripts and summaries. Omit query to list all meetings, most recent first. Returns a 1-based index for each match — pass that index to get_transcript/get_summary. Indices reflect the current meeting list order and are not stable identifiers across separate search_meetings calls if new meetings are recorded in between.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive text to search for in transcripts and summaries. Omit to list everything.")
                    ])
                ])
            ])
        ),
        Tool(
            name: "get_transcript",
            description: "Get the full transcript for one meeting, by the index returned from the most recent search_meetings call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "meetingIndex": .object([
                        "type": .string("integer"),
                        "description": .string("1-based index from search_meetings")
                    ])
                ]),
                "required": .array([.string("meetingIndex")])
            ])
        ),
        Tool(
            name: "get_summary",
            description: "Get the local-LLM-generated summary for one meeting, by the index returned from the most recent search_meetings call. Returns a message if no summary exists yet (e.g. Ollama wasn't available when the meeting was recorded).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "meetingIndex": .object([
                        "type": .string("integer"),
                        "description": .string("1-based index from search_meetings")
                    ])
                ]),
                "required": .array([.string("meetingIndex")])
            ])
        )
    ]

    private static func handleCallTool(params: CallTool.Parameters, store: MeetingStore) async -> CallTool.Result {
        do {
            switch params.name {
            case "search_meetings":
                let query = params.arguments?["query"]?.stringValue
                return textResult(try searchMeetings(query: query, store: store))
            case "get_transcript":
                guard let index = meetingIndex(from: params.arguments) else {
                    return textResult("meetingIndex is required and must be an integer.", isError: true)
                }
                return textResult(try transcript(at: index, store: store))
            case "get_summary":
                guard let index = meetingIndex(from: params.arguments) else {
                    return textResult("meetingIndex is required and must be an integer.", isError: true)
                }
                return textResult(try summary(at: index, store: store))
            default:
                return textResult("Unknown tool: \(params.name)", isError: true)
            }
        } catch {
            return textResult("Error: \(error)", isError: true)
        }
    }

    private static func textResult(_ text: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }

    // MARK: - Pure logic (unit-testable without a live MCP transport)

    static func meetingIndex(from arguments: [String: Value]?) -> Int? {
        arguments?["meetingIndex"]?.intValue
    }

    static func searchMeetings(query: String?, store: MeetingStore) throws -> String {
        let all = try store.allMeetings()
        let matches: [(offset: Int, element: Meeting)]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let needle = query.lowercased()
            matches = all.enumerated().filter { _, meeting in
                (meeting.transcriptText?.lowercased().contains(needle) ?? false)
                    || (meeting.summaryText?.lowercased().contains(needle) ?? false)
            }
        } else {
            matches = Array(all.enumerated())
        }

        guard !matches.isEmpty else {
            return query.map { "No meetings match \"\($0)\"." } ?? "No meetings recorded yet."
        }

        return matches
            .map { MeetingBrowser.listLine(index: $0.offset + 1, meeting: $0.element) }
            .joined(separator: "\n\n")
    }

    static func transcript(at index: Int, store: MeetingStore) throws -> String {
        let all = try store.allMeetings()
        guard let meeting = all[safe: index - 1] else {
            return "No meeting #\(index). Valid range: 1-\(all.count)."
        }
        return meeting.transcriptText ?? "No transcript yet for this meeting."
    }

    static func summary(at index: Int, store: MeetingStore) throws -> String {
        let all = try store.allMeetings()
        guard let meeting = all[safe: index - 1] else {
            return "No meeting #\(index). Valid range: 1-\(all.count)."
        }
        return meeting.summaryText ?? "No summary yet for this meeting (Ollama may not have been available when it was recorded)."
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
