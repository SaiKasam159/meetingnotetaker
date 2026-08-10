import XCTest
import AVFoundation
@testable import MeetingNoteTaker

private enum FakeWriterError: Error {
    case diskFull
}

private final class ThrowingAudioFileWriter: AudioFileWriting {
    func write(from buffer: AVAudioPCMBuffer) throws {
        throw FakeWriterError.diskFull
    }
}

private final class SucceedingAudioFileWriter: AudioFileWriting {
    private(set) var writeCount = 0
    func write(from buffer: AVAudioPCMBuffer) throws {
        writeCount += 1
    }
}

final class AudioRecorderTests: XCTestCase {
    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
    }

    // MARK: - writePCMBuffer / lastError

    func testWritePCMBufferSetsLastErrorOnFailure() {
        let recorder = AudioRecorder()
        recorder.audioFile = ThrowingAudioFileWriter()

        recorder.writePCMBuffer(makeBuffer())

        XCTAssertNotNil(recorder.lastError)
        XCTAssertTrue(recorder.lastError is FakeWriterError)
    }

    func testWritePCMBufferSucceedsWithoutSettingLastError() {
        let recorder = AudioRecorder()
        let writer = SucceedingAudioFileWriter()
        recorder.audioFile = writer

        recorder.writePCMBuffer(makeBuffer())

        XCTAssertNil(recorder.lastError)
        XCTAssertEqual(writer.writeCount, 1)
    }

    func testWritePCMBufferWithNoAudioFileDoesNothing() {
        let recorder = AudioRecorder()
        recorder.audioFile = nil

        recorder.writePCMBuffer(makeBuffer())

        XCTAssertNil(recorder.lastError)
    }

    // MARK: - finalizeCaptureError (pure, no live capture needed)

    func testFinalizeCaptureErrorThrowsWrappedWhenErrorPresent() {
        XCTAssertThrowsError(try AudioRecorder.finalizeCaptureError(FakeWriterError.diskFull)) { error in
            guard case RecorderError.captureFailed(let underlying) = error else {
                XCTFail("Expected .captureFailed, got \(error)")
                return
            }
            XCTAssertTrue(underlying is FakeWriterError)
        }
    }

    func testFinalizeCaptureErrorDoesNothingWhenNil() {
        XCTAssertNoThrow(try AudioRecorder.finalizeCaptureError(nil))
    }
}
