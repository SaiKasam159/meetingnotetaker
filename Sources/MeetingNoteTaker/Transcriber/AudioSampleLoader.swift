import Foundation
import AVFoundation

enum AudioSampleLoaderError: Error {
    case cannotOpenFile(String)
    case converterCreationFailed
    case conversionFailed(String)
}

/// Decodes a recorded .caf file (48kHz stereo, per AudioRecorder's capture
/// format) into the 16kHz mono Float32 PCM samples whisper.cpp requires.
enum AudioSampleLoader {
    static let whisperSampleRate: Double = 16_000
    private static let outputChunkFrameCapacity: AVAudioFrameCount = 16_000 * 4 // 4s per pull, arbitrary but reasonable

    static func loadMonoFloat32Samples(from url: URL) throws -> [Float] {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: url)
        } catch {
            throw AudioSampleLoaderError.cannotOpenFile(error.localizedDescription)
        }

        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioSampleLoaderError.converterCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioSampleLoaderError.converterCreationFailed
        }

        let frameCount = AVAudioFrameCount(inputFile.length)
        guard frameCount > 0, let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return []
        }
        try inputFile.read(into: inputBuffer)

        // AVAudioConverter.convert(to:error:withInputFrom:) does NOT
        // guarantee draining all available output in a single call — a
        // resampling converter can return .haveData having only partially
        // filled the output buffer, or need several calls to fully consume
        // the input. Loop until the input block has nothing left to give
        // AND the converter reports it's drained, accumulating every chunk.
        nonisolated(unsafe) var suppliedInput = false
        nonisolated(unsafe) let unsafeInputBuffer = inputBuffer
        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(Double(frameCount) * (outputFormat.sampleRate / inputFormat.sampleRate)) + Int(outputChunkFrameCapacity))

        conversionLoop: while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputChunkFrameCapacity) else {
                throw AudioSampleLoaderError.converterCreationFailed
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return unsafeInputBuffer
            }

            let producedFrames = outputBuffer.frameLength > 0
            if producedFrames, let channelData = outputBuffer.floatChannelData {
                let chunk = UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
                allSamples.append(contentsOf: chunk)
            }

            switch status {
            case .haveData:
                // Safety valve: once our single input buffer has been handed
                // over and a pull produces nothing new, the converter is
                // drained even if it keeps reporting .haveData — without
                // this, an edge case here would loop forever.
                if suppliedInput, !producedFrames {
                    break conversionLoop
                }
                continue conversionLoop // more output may still be buffered internally — keep pulling
            case .inputRanDry:
                if suppliedInput {
                    // We already handed over our one input buffer and the
                    // converter has nothing left internally either — done.
                    break conversionLoop
                }
                continue conversionLoop
            case .endOfStream:
                break conversionLoop
            case .error:
                throw AudioSampleLoaderError.conversionFailed(error?.localizedDescription ?? "unknown conversion error")
            @unknown default:
                break conversionLoop
            }
        }

        return allSamples
    }
}
