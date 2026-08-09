# TODOS

## Accepted risk: iCloud-exclusion silent-failure mode (storage location)

**What:** Storage lives in ~/Documents/MeetingNoteTaker with an iCloud Drive sync-exclusion flag, rather than the iCloud-safe-by-default ~/Library/Application Support.
**Why this is recorded here:** The outside-voice cross-model review during eng review flagged that the exclusion flag is a single point of silent failure against the project's core "100% local" promise (OS update, user toggling Desktop & Documents sync, or the attribute not surviving a file move could all silently leak data to iCloud with no error or test signal). Explicitly accepted in favor of Finder discoverability rather than switching to Application Support.
**Mitigation not currently planned:** A startup verification check that re-confirms/re-applies the exclusion attribute was offered as a middle-ground option and declined. Revisit if this risk becomes a real incident, or before recommending this tool to the small team/close group given they'd be trusting the same guarantee.

Captured during `/plan-eng-review` on 2026-08-09, deferred from Phase 1 (audio capture + Whisper.cpp transcription + local storage).

## Speaker diarization

**What:** Label who said what in transcripts.
**Why:** Action items need an owner to be useful once written to Google Calendar/Gmail, but attribution isn't designed yet.
**Pros:** Makes extracted action items actually actionable rather than anonymous text.
**Cons:** Real complexity (diarization models, per-speaker audio separation). Not needed for Phase 1, which only captures and transcribes.
**Context:** Surfaced during the adversarial design-doc review and confirmed during eng review. Decide before Phase 2's Ollama-based action-item extraction work starts, since the extraction prompts and Calendar/email write-back logic depend on whether attribution exists.
**Depends on / blocked by:** Phase 1 shipping first.

## Data retention / deletion policy

**What:** Decide whether raw audio and transcripts are kept forever or auto-pruned, and build the policy.
**Why:** Local disk grows unbounded otherwise — audio files are large, and no compression or diarization-based trimming is decided yet.
**Pros:** Prevents silent disk bloat; gives the user control over how much history is kept.
**Cons:** Adds a settings surface and a background cleanup job that aren't needed to prove the core pipeline works.
**Context:** Flagged in the adversarial design-doc review as a missing requirement. Easier to bake a retention field into the storage schema now (Phase 1) than retrofit it after data has already accumulated without one.
**Depends on / blocked by:** Phase 1 storage schema design.

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

## MCP server auth model (Phase 2)

**What:** Decide and implement an auth model for the Phase 2 MCP server before it ships — e.g. a local auth token, or a Unix socket scoped by file permissions rather than an open TCP port.
**Why:** An unauthenticated localhost server exposing "search all meeting transcripts" is a new local attack surface — any other local process could query it. This undercuts the "nothing leaves the device except the bounded Calendar/Gmail exception" pitch, since the exception list never accounted for other local processes reaching in.
**Pros:** Closes a real gap in the local-only threat model before it exists, not after.
**Cons:** Adds design work to Phase 2's MCP server scope. Doesn't block Phase 1.
**Context:** Surfaced by the outside-voice cross-model review during eng review. Not caught by the original architecture review since MCP wasn't in scope for Phase 1.
**Depends on / blocked by:** Phase 2 MCP server design.

## Encryption at rest

**What:** Decide whether the local transcript/audio store should be encrypted on disk, and implement it if so.
**Why:** Raises the privacy bar if the laptop is lost, stolen, or shared — meeting content is sensitive, and the whole project's premise is privacy.
**Pros:** Stronger privacy guarantee, consistent with the "must run and store locally" positioning against Granola.
**Cons:** Adds real complexity (key management, macOS Keychain integration for the encryption key itself). Not needed to prove the core pipeline works.
**Context:** Raised during eng review. Worth deciding deliberately rather than defaulting to plaintext storage by accident. macOS FileVault (full-disk encryption) provides a baseline if enabled, which may be sufficient depending on the threat model chosen.
**Depends on / blocked by:** Phase 1 storage schema design.
