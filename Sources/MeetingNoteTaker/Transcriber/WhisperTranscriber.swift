import Foundation
import CWhisper

/// Wraps whisper.cpp (vendored as a git submodule at Vendor/whisper.cpp,
/// pinned to v1.9.2) for fully local transcription. No network access.
///
/// Model file NOT yet provided — whisper_init_from_file_with_params will
/// fail fast with a clear error until a ggml model (e.g. ggml-base.en.bin)
/// is downloaded and its path passed to init(modelPath:). Model size vs.
/// accuracy vs. download size is a deliberate open decision, not made here.
final class WhisperTranscriber: Transcribing, Sendable {
    /// Long meetings must not hang transcription indefinitely — bounded per
    /// the eng review's feasibility finding on whisper.cpp given very long
    /// recordings.
    private let timeout: TimeInterval = 20 * 60
    private let modelPath: URL

    /// A ggml model file (e.g. ggml-base.en.bin) must be downloaded
    /// separately and its path supplied here — not bundled by this scaffold.
    /// See TODOS.md-adjacent note in the type doc: model size vs. accuracy
    /// vs. download size is a deliberate open decision, not made here.
    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    func transcribe(audioFileURL: URL, onStatusChange: @escaping @Sendable (TranscriptionStatus) -> Void) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw TranscriberError.audioFileMissing
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: audioFileURL.path)
        let size = (attributes[.size] as? Int) ?? 0
        guard size > 0 else {
            throw TranscriberError.audioFileEmpty
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscriberError.underlyingEngineFailure("Whisper model not found at \(modelPath.path). Download a ggml model (e.g. ggml-base.en.bin) first.")
        }

        onStatusChange(.transcribing(progress: 0))

        do {
            let result = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.runInference(audioFileURL: audioFileURL, onStatusChange: onStatusChange)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    throw TranscriberError.timedOut
                }
                guard let first = try await group.next() else {
                    throw TranscriberError.timedOut
                }
                group.cancelAll()
                return first
            }
            onStatusChange(.finished(result))
            return result
        } catch {
            onStatusChange(.failed(error))
            throw error
        }
    }

    /// whisper_full is a long-running, synchronous, blocking C call — it must
    /// not run directly on a Swift concurrency cooperative-pool thread (that
    /// would starve the pool for the whole transcription). Bridged onto a
    /// dedicated background thread instead, per the eng review decision that
    /// transcription runs in the background with a status indicator.
    private func runInference(audioFileURL: URL, onStatusChange: @escaping @Sendable (TranscriptionStatus) -> Void) async throws -> String {
        let samples = try AudioSampleLoader.loadMonoFloat32Samples(from: audioFileURL)
        guard !samples.isEmpty else {
            throw TranscriberError.audioFileEmpty
        }

        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    let text = try Self.runWhisperFull(samples: samples, modelPath: self.modelPath, onStatusChange: onStatusChange)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.stackSize = 8 << 20 // whisper.cpp's C++ call stack can run deep; default 512KB is tight.
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// The actual whisper.cpp C API call. Static + all state passed as
    /// parameters so this closure has no captured mutable state to race on
    /// across the dedicated thread boundary.
    private static func runWhisperFull(
        samples: [Float],
        modelPath: URL,
        onStatusChange: @escaping @Sendable (TranscriptionStatus) -> Void
    ) throws -> String {
        var contextParams = whisper_context_default_params()
        // Metal GPU produces garbled transcription output on this machine's
        // discrete AMD GPU (AMD Radeon Pro 5300M) — confirmed via a real
        // end-to-end test against whisper.cpp's own known-good jfk.wav
        // sample: use_gpu=true returned "a"; use_gpu=false returned the
        // correct speech. CPU + Accelerate/BLAS is proven correct and still
        // reasonably fast (~9s for 11s of audio with small.en). This may be
        // specific to older Intel Macs with a discrete AMD GPU rather than a
        // general whisper.cpp/Metal problem — worth re-testing on Apple
        // Silicon hardware, where the unified GPU may not hit the same bug,
        // before assuming CPU-only should stay the permanent default.
        contextParams.use_gpu = false

        guard let context = whisper_init_from_file_with_params(modelPath.path, contextParams) else {
            throw TranscriberError.underlyingEngineFailure("whisper_init_from_file_with_params failed — check the model file at \(modelPath.path) is a valid ggml model.")
        }
        defer { whisper_free(context) }

        var fullParams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        fullParams.print_progress = false
        fullParams.print_special = false
        fullParams.print_realtime = false
        fullParams.print_timestamps = false

        let result = samples.withUnsafeBufferPointer { buffer -> Int32 in
            whisper_full(context, fullParams, buffer.baseAddress, Int32(buffer.count))
        }
        guard result == 0 else {
            throw TranscriberError.underlyingEngineFailure("whisper_full returned non-zero status: \(result)")
        }

        let segmentCount = whisper_full_n_segments(context)
        guard segmentCount > 0 else {
            return ""
        }

        var transcript = ""
        for i in 0..<segmentCount {
            onStatusChange(.transcribing(progress: Double(i) / Double(segmentCount)))
            if let cText = whisper_full_get_segment_text(context, i) {
                transcript += String(cString: cText)
            }
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
