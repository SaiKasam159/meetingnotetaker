# TODOS

## Accepted risk: iCloud-exclusion silent-failure mode (storage location)

**What:** Storage lives in ~/Documents/MeetingNoteTaker with an iCloud Drive sync-exclusion flag, rather than the iCloud-safe-by-default ~/Library/Application Support.
**Why this is recorded here:** The outside-voice cross-model review during eng review flagged that the exclusion flag is a single point of silent failure against the project's core "100% local" promise (OS update, user toggling Desktop & Documents sync, or the attribute not surviving a file move could all silently leak data to iCloud with no error or test signal). Explicitly accepted in favor of Finder discoverability rather than switching to Application Support.
**Mitigation not currently planned:** A startup verification check that re-confirms/re-applies the exclusion attribute was offered as a middle-ground option and declined. Revisit if this risk becomes a real incident, or before recommending this tool to the small team/close group given they'd be trusting the same guarantee.

Captured during `/plan-eng-review` on 2026-08-09, deferred from Phase 1 (audio capture + Whisper.cpp transcription + local storage).

## Resolved: Ollama cloud-inference lockout

**What:** Ollama (used for local summarization, see "Reasoning/summarization" architecture decision) ships an optional cloud-inference feature that can route some model calls to ollama.com instead of running them on-device — directly at odds with this project's "must run and store 100% locally" premise.
**Why this is recorded here:** Discovered while wiring the Phase 2 Ollama integration (2026-08-10) — not something the original design doc anticipated, since this Ollama feature postdates it. A plain `ollama serve` launched by double-clicking Ollama.app does not have cloud disabled by default.
**Resolution:** `OllamaServerManager` (Sources/MeetingNoteTaker/Summarization/OllamaServerManager.swift) launches its own `ollama serve` process with `OLLAMA_NO_CLOUD=true` forced in the environment, rather than relying on a separately-launched Ollama.app. If a server is already running on port 11434 when the app starts, `ensureRunning()` returns `.reusedExisting` rather than silently trusting it — there's no API to verify a pre-existing server's cloud setting, so the app warns the user instead of assuming it's safe (same "warn, don't silently assume" posture used for the FileVault check).
**Depends on / blocked by:** None — implemented as part of the Phase 2 Ollama integration.

## Speaker diarization — RESOLVED 2026-08-11, hard gate cleared

**What:** Label who said what in transcripts.
**Why:** Action items need an owner to be useful once written to Google Calendar/Gmail.
**Decision (locked 2026-08-11):** Real N-speaker diarization, implemented by vendoring **sherpa-onnx** (github.com/k2-fsa/sherpa-onnx, Apache 2.0) and running the pyannote segmentation 3.0 model plus a WeSpeaker English embedding extractor entirely on-device via ONNX Runtime. This clears the hard gate below — Ollama action-item extraction is unblocked, and `get_action_items` can be exposed from the MCP server once extraction exists.

**Why sherpa-onnx and not the Swift-native options:** The Swift-native CoreML diarization SDKs surveyed on 2026-08-11 — FluidAudio (Apache 2.0, pyannote Community-1 via ANE), SpeakerKit (pyannote v4 on Core ML), and speech-swift (MLX) — are all **Apple Silicon only**. FluidAudio and SpeakerKit offload inference to the Apple Neural Engine, and MLX requires Apple Silicon's unified memory architecture by design. This dev machine is an Intel Mac (Radeon Pro 5300M — the same machine whose discrete GPU forced `use_gpu = false` for Whisper, see "Re-test Metal GPU acceleration on Apple Silicon"). sherpa-onnx runs on ONNX Runtime with explicit x86_64 support, so it is the only surveyed option that produces real speaker identity on the machine the project is actually being built on. It also fits the pattern already proven here: a vendored C/C++ library with its own CMake build, linked into SwiftPM through a header-only shim target, exactly like `Vendor/whisper.cpp` and `Sources/CWhisper`.

**Why not the cheaper alternatives that were considered and rejected:**
- whisper.cpp `tinydiarize` (`-tdrz`) — rejected during the Phase 1 hardening pass (2026-08-10) and still rejected. It detects speaker-turn changes, not verified identity, so labels drift once a third speaker re-enters a conversation.
- Mic/system-audio channel split — `AudioRecorder` already registers `.microphone` and `.audio` as two separate `SCStream` outputs and merges them into one file in our own code, so splitting them would yield verified two-way attribution ("you" vs "everyone else") with zero new dependencies. Rejected as the *decision* because it collapses all remote participants into one bucket, which is only complete diarization for 1:1 calls. Worth revisiting as a complement rather than a substitute: the mic channel gives *verified* identity for the local user, which sherpa-onnx can only infer, and that is the one identity that matters most for Calendar/Gmail write-back.
- pyannote as a Python sidecar — works on Intel, but drags a Python runtime into a shipped Swift app.
- Deferring until an Apple Silicon Mac is available — rejected; that is exactly the open-ended deferral the hard gate was written to prevent.

**Pros:** Real per-speaker identity, fully offline, permissively licensed, works on the current Intel dev machine and on Apple Silicon.
**Cons:** A second vendored C++ dependency with its own CMake build and linker flags; two more model files to download and eventually ship; clustering needs tuning (see below); the segmentation plus embedding pipeline costs meaningful extra CPU time on top of transcription, on a machine with no usable GPU acceleration. Benchmark the added wall-clock cost on a real meeting recording before wiring diarization into the default `run()` path.

**Hard gate (now cleared):** Required a decision — proper diarization, or an explicit "ship Phase 2 with unattributed action items" fallback — before the first line of Ollama action-item extraction code. Milestone-gated rather than date-gated, chosen deliberately after an outside-voice review flagged that "keep researching" with no concrete trigger risks leaving this permanently unresolved.
**Depends on / blocked by:** Nothing blocking the decision. Implementation is blocked on returning to a Mac — see HANDOFF.md "Speaker diarization via sherpa-onnx" for the verified integration recipe (model URLs, C API shape, config fields, build steps).

## Data retention / deletion policy

**What:** Decide whether raw audio and transcripts are kept forever or auto-pruned, and build the policy.
**Why:** Local disk grows unbounded otherwise — audio files are large, and no compression or diarization-based trimming is decided yet.
**Decision (locked 2026-08-10, during Phase 1 hardening pass):** Auto-delete raw audio 7 days after recording (grace period to allow re-running transcription against the source audio if a transcript comes out bad). Transcripts are kept indefinitely. `Meeting.retainUntil` is set at insert time (which now happens right after recording stops, not after transcription — see "untranscribed audio" note below); `Meeting.audioDeletedAt` marks when audio was actually removed, with `audioFilePath` kept as a historical record rather than nulled out. `MeetingStore.deleteExpiredAudio()` runs once at app startup, before the interactive recording prompt. Building this surfaced (and fixed) a real gap: a `Meeting` row is now inserted immediately after recording stops, before transcription is attempted — previously, audio that failed to transcribe (e.g. missing model) got no DB row and was permanently exempt from retention, which was the exact audio most likely to accumulate unreviewed.
**Pros:** Prevents silent disk bloat; a real deletion policy now covers 100% of recorded audio, not just the successfully-transcribed subset.
**Cons:** No settings surface to change the 7-day window yet (hardcoded) — deferred until there's a UI (Phase 2) to expose it. No way to browse/list meetings before deletion happens yet either — flagged by an outside-voice review as a real gap; accepted as a known limitation for this pass rather than blocking on building a browse command first.
**Context:** Flagged in the adversarial design-doc review as a missing requirement. Implemented during the Phase 1 hardening pass; see HANDOFF.md history in git log around 2026-08-10 for the full design discussion including the outside-voice findings that shaped the final implementation (DB migration approach, startup sequencing, the untranscribed-audio blind spot fix).
**Depends on / blocked by:** None — implemented as part of the Phase 1 hardening pass.

## Remote-participant consent notification

**What:** Decide and build the actual mechanism (in-meeting chat message, verbal announcement, or similar) that tells remote Zoom/Meet/Teams participants they are being recorded.
**Why:** Two-party/all-party consent laws apply in many jurisdictions. The on-screen recording indicator only covers the local user — it does nothing for remote participants who can't see it.
**Pros:** Mitigates real legal risk once this tool is used with anyone other than the builder.
**Cons:** Real product-design and legal-research work. Blocks nothing in Phase 1 since that phase is solo-use only.
**Context:** Flagged in both the adversarial design-doc review and the eng review as under-specified. The outside-voice cross-model review during eng review sharpened this: Phase 1 testing itself involves real meetings with other people the moment you use it on an actual call, not just once the small team starts using the app. Interim measure while this TODO is open: manually announce verbally that a call is being recorded, starting with the first real-meeting test of Phase 1. Automated tooling remains deferred, but the manual announcement is not optional.
**Depends on / blocked by:** Phase 1 shipping for the automated version; the manual verbal announcement applies immediately.

## Re-test Metal GPU acceleration on Apple Silicon

**What:** WhisperTranscriber currently forces `use_gpu = false` (CPU + Accelerate/BLAS only), disabling Metal acceleration entirely.
**Why:** Confirmed via a real end-to-end test against whisper.cpp's own known-good sample audio (jfk.wav): with Metal enabled, transcription output was garbled ("a" instead of the actual speech) on this dev machine's discrete AMD GPU (AMD Radeon Pro 5300M, an older Intel Mac). With Metal disabled, transcription was correct. This looks like a real numerical/compatibility issue with this specific GPU, not a bug in our audio pipeline — CPU-only was proven correct by the same test.
**Pros of re-testing:** Metal acceleration would meaningfully speed up transcription, especially for longer meetings and larger models. Apple Silicon Macs use a unified GPU architecture that may not hit the same bug this discrete AMD GPU does.
**Cons:** Needs actual Apple Silicon hardware to verify — can't be resolved on this machine. Until re-tested and confirmed safe, CPU-only stays the correct default; shipping with Metal enabled by default without verifying on real target hardware risks garbled transcripts reaching a user silently.
**Context:** See `WhisperTranscriber.runWhisperFull`'s inline comment for the full finding. The end-to-end test (`WhisperTranscriberTests.testTranscribesKnownSampleAudio`) is the regression test to re-run with `use_gpu = true` when testing on Apple Silicon.
**Depends on / blocked by:** Access to an Apple Silicon Mac for testing.

## MCP server auth model (Phase 2) — RESOLVED, decision reversed 2026-08-11

**What:** Decide and implement an auth model for the Phase 2 MCP server before it ships.
**Why:** An unauthenticated localhost server exposing "search all meeting transcripts" would be a new local attack surface — any other local process could query it. This undercuts the "nothing leaves the device except the bounded Calendar/Gmail exception" pitch, since the exception list never accounted for other local processes reaching in.
**Original decision (locked 2026-08-10, during Phase 1 hardening pass):** Unix domain socket, scoped by file permissions to the user's own account — not a TCP port with a bearer token.
**Reversed 2026-08-11, while starting the actual MCP server build:** The Unix-socket decision assumed a threat model that doesn't apply — a persistent daemon that any local process could discover and connect to. That's not how local MCP servers actually get used: Claude Desktop and Claude Code only support **stdio-launched subprocesses** for local servers (confirmed via Claude Desktop's own docs — "Claude Desktop's local config schema validates stdio servers only"). Claude spawns the server binary itself and talks to it over that process's own stdin/stdout pipes, which no other process can attach to — no socket file, no daemon, no discoverable auth surface at all. This is a *stronger* guarantee than a Unix socket (which, despite file permissions, is still a named filesystem object any process running as the user's UID could in principle open) and requires no design work of its own — the official Swift MCP SDK's `StdioTransport` handles it directly.
**Pros:** Simpler implementation than the original plan (no socket lifecycle, no "is a server already running" reuse logic, no daemon supervision) *and* a stronger security property, for free.
**Cons:** None identified — this was a correction of a flawed premise, not a real tradeoff.
**Context:** The original decision was made during the hardening pass's outside-voice review without checking how Claude actually integrates with local MCP servers. Caught while starting the real implementation and verified against Claude Desktop's documented config schema before reversing.
**Depends on / blocked by:** None — implementation proceeds using stdio transport.

## Encryption at rest

**What:** Decide whether the local transcript/audio store should be encrypted on disk, and implement it if so.
**Why:** Raises the privacy bar if the laptop is lost, stolen, or shared — meeting content is sensitive, and the whole project's premise is privacy.
**Decision (locked 2026-08-10, during Phase 1 hardening pass):** FileVault-only — no app-layer encryption (no SQLCipher, no custom AES/Keychain key management). v1's realistic threat model is a lost/stolen *powered-off* laptop, which FileVault (AES-XTS, Secure Enclave-backed on Apple Silicon/T2 Macs) already covers; app-layer encryption would mainly add protection against another logged-in user on the same machine or malware while logged in, neither of which is in scope for solo, single-Mac use. The app checks FileVault status at every launch (`StorageLocation.isFileVaultEnabled()`) and warns (does not block launch) if it's off, matching the existing accepted-risk pattern used for the iCloud-exclusion mitigation.
**Pros:** Real security boundary with zero new infrastructure (key management, migration of existing plaintext data) — matches the actual threat model instead of over-building for one not in scope.
**Cons:** Does not protect against another logged-in user on the same machine, or malware running while logged in. Revisit if the threat model changes (shared-machine use, multi-user).
**Context:** Raised during eng review; resolved during the Phase 1 hardening pass after checking that FileVault (AES-XTS, hardware-backed) already covers the realistic threat model for solo use.
**Depends on / blocked by:** None — implemented as part of the Phase 1 hardening pass.

## Bug: concurrent writes to a single AVAudioFile from two capture queues

**What:** `AudioRecorder.startRecording()` registers two stream outputs on two independent dispatch queues — `.audio` on `"audio.capture.queue"` and `.microphone` on `"mic.capture.queue"` (AudioRecorder.swift:83-84). Both queues' callbacks land in the same `didOutputSampleBuffer` handler, which calls `write(_:)` and then `writePCMBuffer(_:)` on the same `AVAudioFile` instance (AudioRecorder.swift:140-147). `AVAudioFile` is not documented as thread-safe, and nothing here serializes the two queues.
**Why:** This is a data race on every recording that has both system audio and microphone input, which is every real meeting. Consequences range from interleaved/corrupted frames to a crash mid-recording. It has not visibly bitten yet — Phase 1's end-to-end verification produced a usable transcript — which makes it the kind of latent race that surfaces under load (longer meetings, busier machine) rather than in a short test.
**Secondary issue in the same path:** the two streams are being *interleaved* into one file rather than mixed. Each callback appends whatever buffer it happened to receive, so system audio and mic audio alternate in the output file instead of being summed into a single mixed signal.
**Fix direction:** Serialize writes onto one dedicated queue, and decide explicitly whether the two sources should be mixed into one signal or written to two files. Writing them to two files is the better option — it fixes the race structurally (one writer per file) and preserves the mic channel as verified local-speaker identity, which complements sherpa-onnx diarization (see "Speaker diarization"). Note that two files reintroduces the cross-source alignment concern the single-`SCStream` design was chosen to avoid — but only at the file level, not the clock level: both streams still come from the same synchronized ScreenCaptureKit pipeline, so their timestamps remain comparable.
**Context:** Found on 2026-08-11 while surveying diarization options, by reading `AudioRecorder` to check whether mic and system audio were separable at the source. They are.
**Depends on / blocked by:** Needs a Mac to build and verify — cannot be tested on the Windows machine this was found on.

## Bug: AudioSampleLoader's stereo capture only ever fills the left channel

**What:** `AudioRecorder`'s capture config sets `channelCount = 2` (AudioRecorder.swift:73) and the output `AVAudioFormat` is created with `channels: 2` (AudioRecorder.swift:78), but the `CMSampleBuffer.asPCMBuffer(format:)` helper copies into `channelData[0]` only (AudioRecorder.swift:190-194). The right channel of every written buffer is left at whatever `AVAudioPCMBuffer` allocated it as.
**Why:** Recordings are nominally stereo but carry real audio in one channel and uninitialized data in the other. Transcription happens to be unaffected because `AudioSampleLoader.loadMonoFloat32Samples` downmixes to mono at 16 kHz before Whisper sees it — which is also why this went unnoticed. It will matter for anything that consumes the raw `.caf` directly: playback, re-transcription with different tooling, or feeding audio to diarization.
**Fix direction:** Either copy both channels properly, or capture mono deliberately (`channelCount = 1`) and stop claiming stereo. Mono is likely the honest choice — nothing in the product needs a stereo meeting recording, and it halves the audio file size, which interacts well with the 7-day retention policy.
**Context:** Found on 2026-08-11 alongside the concurrent-write race above.
**Depends on / blocked by:** Needs a Mac to build and verify.
