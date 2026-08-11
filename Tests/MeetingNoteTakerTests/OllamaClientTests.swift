import XCTest
@testable import MeetingNoteTaker

private struct StubHTTP: HTTPRequesting {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private func makeResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

final class OllamaClientTests: XCTestCase {
    private let testURL = URL(string: "http://127.0.0.1:11434")!

    func testBuildSummaryPromptIncludesTranscript() {
        let prompt = OllamaClient.buildSummaryPrompt(transcript: "hello world")
        XCTAssertTrue(prompt.contains("hello world"))
        XCTAssertTrue(prompt.lowercased().contains("summarize"))
    }

    func testSummarizeThrowsOnEmptyTranscript() async {
        let client = OllamaClient(http: StubHTTP { _ in
            XCTFail("should not make a network call for an empty transcript")
            throw OllamaError.invalidResponse
        })

        do {
            _ = try await client.summarize(transcript: "   \n  ")
            XCTFail("expected emptyTranscript to be thrown")
        } catch OllamaError.emptyTranscript {
            // expected
        } catch {
            XCTFail("expected emptyTranscript, got \(error)")
        }
    }

    func testSummarizeReturnsTrimmedResponseOnSuccess() async throws {
        let client = OllamaClient(http: StubHTTP { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertNotNil(body["model"])
            let json = try JSONSerialization.data(withJSONObject: ["response": "  a concise summary  \n"])
            return (json, makeResponse(url: self.testURL, statusCode: 200))
        })

        let summary = try await client.summarize(transcript: "we discussed the roadmap")
        XCTAssertEqual(summary, "a concise summary")
    }

    func testSummarizeThrowsServerUnreachableOnTransportError() async {
        struct FakeTransportError: Error {}
        let client = OllamaClient(http: StubHTTP { _ in throw FakeTransportError() })

        do {
            _ = try await client.summarize(transcript: "hello")
            XCTFail("expected serverUnreachable to be thrown")
        } catch OllamaError.serverUnreachable {
            // expected
        } catch {
            XCTFail("expected serverUnreachable, got \(error)")
        }
    }

    func testSummarizeThrowsInvalidResponseOnNon200() async {
        let client = OllamaClient(http: StubHTTP { request in
            (Data(), makeResponse(url: self.testURL, statusCode: 500))
        })

        do {
            _ = try await client.summarize(transcript: "hello")
            XCTFail("expected invalidResponse to be thrown")
        } catch OllamaError.invalidResponse {
            // expected
        } catch {
            XCTFail("expected invalidResponse, got \(error)")
        }
    }

    func testSummarizeThrowsInvalidResponseOnMalformedJSON() async {
        let client = OllamaClient(http: StubHTTP { request in
            (Data("not json".utf8), makeResponse(url: self.testURL, statusCode: 200))
        })

        do {
            _ = try await client.summarize(transcript: "hello")
            XCTFail("expected invalidResponse to be thrown")
        } catch OllamaError.invalidResponse {
            // expected
        } catch {
            XCTFail("expected invalidResponse, got \(error)")
        }
    }
}
