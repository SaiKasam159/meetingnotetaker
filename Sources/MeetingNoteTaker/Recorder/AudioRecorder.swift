import Foundation
import ScreenCaptureKit
import AVFoundation

enum RecorderError: Error {
    case permissionDenied
    case noDisplayAvailable
    case alreadyRecording
    case notRecording
    case captureFailed(underlying: Error)
}

/// Narrow seam around AVAudioFile.write(from:) so AudioRecorder's
/// write-error handling can be exercised with a throwing test double instead
/// of requiring a real disk-full condition. AVAudioFile already conforms to
/// this structurally, so production code needs no wrapping.
protocol AudioFileWriting {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: AudioFileWriting {}

/// Captures system audio and microphone audio through a single
/// ScreenCaptureKit stream (SCStreamConfiguration.captureMicrophone +
/// .capturesAudio together), rather than pairing ScreenCaptureKit with a
/// separate AVAudioEngine mic tap. Both signals arrive through the same
/// synchronized capture pipeline, which sidesteps the cross-stream clock
/// drift that two independently-clocked APIs would introduce over a long
/// recording (see TODOS.md / eng review outside-voice finding).
///
/// Writes incrementally to an AVAudioFile so a crash or force-quit leaves a
/// valid, playable partial file rather than a corrupt one — RecordingRecovery
/// picks up any file left in-progress on the next launch.
final class AudioRecorder: NSObject {
    private var stream: SCStream?
    // Not `private` (default `internal`): tests inject a throwing double via
    // @testable import to exercise the write-error path in writePCMBuffer(_:)
    // without needing a real disk-full condition or live capture.
    var audioFile: AudioFileWriting?
    private var captureFormat: AVAudioFormat?
    private var currentSession: RecordingSession?
    private let recoveryMarker = RecordingRecovery()

    private(set) var isRecording = false
    /// Set when a write fails (disk full, etc.) or the stream stops
    /// unexpectedly (didStopWithError). stopRecording() surfaces this as
    /// RecorderError.captureFailed instead of losing it silently.
    private(set) var lastError: Error?

    func startRecording() async throws -> RecordingSession {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        guard await PermissionManager.checkSystemAudioPermission() == .granted else {
            throw RecorderError.permissionDenied
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplayAvailable
        }

        // Audio-only capture: exclude on-screen content, we only want the
        // audio tracks. An empty content filter still requires a display
        // reference internally, hence resolving `display` above even though
        // no video is captured.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let session = try RecordingSession.startNew()
        try recoveryMarker.markInProgress(session)

        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        captureFormat = outputFormat
        audioFile = try AVAudioFile(forWriting: session.audioFileURL, settings: outputFormat.settings)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.capture.queue"))
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "mic.capture.queue"))
        try await newStream.startCapture()

        self.stream = newStream
        self.currentSession = session
        self.isRecording = true
        return session
    }

    func stopRecording() async throws -> RecordingSession {
        guard isRecording, let session = currentSession, let activeStream = stream else {
            // Not recording — most likely the stream already died via
            // didStopWithError. Surface whatever it recorded instead of a
            // generic .notRecording that hides the real cause.
            let error = lastError
            lastError = nil
            try Self.finalizeCaptureError(error)
            throw RecorderError.notRecording
        }

        try await activeStream.stopCapture()
        audioFile = nil
        stream = nil
        isRecording = false
        currentSession = nil

        var finished = session
        finished.endedAt = Date()
        try recoveryMarker.markFinished(finished)

        let error = lastError
        lastError = nil
        try Self.finalizeCaptureError(error)

        return finished
    }

    /// Pure throw-decision, split out so it's unit-testable without a live
    /// SCStream or AudioRecorder instance at all — just call it with an
    /// Error? and check whether/what it throws.
    static func finalizeCaptureError(_ error: Error?) throws {
        if let error {
            throw RecorderError.captureFailed(underlying: error)
        }
    }

    private func write(_ sampleBuffer: CMSampleBuffer) {
        guard let captureFormat, let pcmBuffer = sampleBuffer.asPCMBuffer(format: captureFormat) else {
            return
        }
        writePCMBuffer(pcmBuffer)
    }

    /// Not `private`: exercised directly by tests with a throwing
    /// AudioFileWriting double, bypassing the need for a real CMSampleBuffer
    /// or live capture.
    func writePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile else { return }
        do {
            try audioFile.write(from: buffer)
        } catch {
            lastError = error
        }
    }
}

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        guard sampleBuffer.isValid else { return }
        write(sampleBuffer)
    }
}

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The stream stopped unexpectedly (not via our own stopRecording()).
        // Leave the in-progress marker in place — RecordingRecovery will
        // pick this up as an orphaned recording on next launch rather than
        // silently losing the failure. Store the error and clear state so a
        // subsequent stopRecording() call surfaces the real cause instead of
        // a misleading .notRecording, and so stream/audioFile/currentSession
        // don't linger as stale references.
        lastError = error
        self.stream = nil
        audioFile = nil
        currentSession = nil
        isRecording = false
    }
}

private extension CMSampleBuffer {
    func asPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        let frameCount = AVAudioFrameCount(numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer else {
            return nil
        }

        if let channelData = pcmBuffer.floatChannelData {
            dataPointer.withMemoryRebound(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size) { floatPointer in
                channelData[0].update(from: floatPointer, count: Int(frameCount))
            }
        }
        return pcmBuffer
    }
}
