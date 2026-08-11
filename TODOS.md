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

## Speaker diarization

**What:** Label who said what in transcripts.
**Why:** Action items need an owner to be useful once written to Google Calendar/Gmail, but attribution isn't designed yet.
**Pros:** Makes extracted action items actually actionable rather than anonymous text.
**Cons:** Real complexity (diarization models, per-speaker audio separation). Not needed for Phase 1, which only captures and transcribes.
**Context:** Surfaced during the adversarial design-doc review and confirmed during eng review. During the Phase 1 hardening pass (2026-08-10), whisper.cpp's experimental "tinydiarize" model variant (`-tdrz`, already part of the vendored submodule, no new dependency) was evaluated as a pragmatic v1 option and explicitly rejected: it only detects speaker-turn changes ("someone new started talking"), not verified speaker identity, so labels can drift/misattribute once a 3rd+ speaker re-enters a conversation. Research into a proper speaker-identity approach (e.g. a local pyannote-based sidecar process) continues separately.
**Hard gate:** Must be decided — proper diarization, or an explicit "ship Phase 2 with unattributed action items" fallback — before the first line of Ollama action-item extraction code is written. Milestone-gated rather than date-gated, chosen deliberately after an outside-voice review flagged that "keep researching" with no concrete trigger risks leaving this permanently unresolved.
**Depends on / blocked by:** Phase 1 shipping first (done). Blocks the start of Phase 2's Ollama extraction implementation.

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
