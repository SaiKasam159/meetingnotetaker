import Foundation

enum OllamaError: Error {
    case emptyTranscript
    case serverUnreachable
    case invalidResponse
}

/// Narrow seam around the network call so summarize(transcript:) is
/// unit-testable with a stubbed response instead of a live Ollama server.
/// URLSession already conforms structurally (its `data(for:)` signature
/// matches exactly), so production code needs no wrapping.
protocol HTTPRequesting {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPRequesting {}

/// Talks to a local Ollama server's HTTP API to summarize meeting
/// transcripts. No network access beyond 127.0.0.1 — the whole point of
/// Approach A (fully local via Ollama, see the design doc) is that
/// transcript text never leaves the device for reasoning.
final class OllamaClient {
    private let baseURL: URL
    private let model: String
    private let http: HTTPRequesting

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String = "llama3.1:8b", http: HTTPRequesting = URLSession.shared) {
        self.baseURL = baseURL
        self.model = model
        self.http = http
    }

    func summarize(transcript: String) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OllamaError.emptyTranscript
        }
        return try await generate(prompt: Self.buildSummaryPrompt(transcript: transcript))
    }

    /// Pure prompt construction, split out so it's directly testable without
    /// a network call.
    static func buildSummaryPrompt(transcript: String) -> String {
        """
        Summarize the following meeting transcript in 3-5 concise sentences. \
        Focus on what was discussed and any decisions made. Output only the \
        summary itself — no preamble like "Here is a summary".

        Transcript:
        \(transcript)
        """
    }

    private func generate(prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "prompt": prompt,
            "stream": false
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            throw OllamaError.serverUnreachable
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.invalidResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw OllamaError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
