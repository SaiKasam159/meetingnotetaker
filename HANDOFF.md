---
status: in-progress
branch: main
timestamp: 2026-08-11T13:15:00Z
files_modified: []
---

## Working on: meetingnotetaker — Phase 1 hardened, Phase 2 in progress (Ollama summarization + MCP server built; Calendar/Gmail/UI not started)

### Summary

meetingnotetaker is a local-first macOS replica of Granola: record meetings (mic +
system audio), transcribe locally via whisper.cpp, store everything on-disk, no cloud
except a narrow bounded exception for user-initiated Google Calendar/Gmail writes.
**Phase 1 is fully built, hardened, tested, and committed** — verified end-to-end
against a real recording, then hardened (FileVault boundary, audio retention,
error-surfacing fixes) through a full `/plan-eng-review` with all 22 tests passing.
**Phase 2 has started:** Ollama is installed and wired for local summarization (33
tests passing total), with a real finding along the way — Ollama has an optional
cloud-inference feature that had to be explicitly locked out to keep the "100% local"
guarantee. MCP server, Google Calendar/Gmail write-back, and the real UI (replacing
the current `readLine()` CLI) have not started.

### Repo / environment this assumes

- Repo: `meetingnotetaker`, `main` branch, clean working tree at the time of this save.
- This machine's `~/.gstack/projects/meetingnotetaker/` holds gstack review artifacts
  (design doc, test plan, tasks JSONL, review log) that **do not travel with
  `git clone`/`git pull`** — local machine state, not repo content. Everything
  load-bearing from them is inlined below.

### Toolchain setup required on a new machine (none of this is optional — Phase 1 will not build without all of it)

1. **Full Xcode.app, not just Command Line Tools.** CLT-only was missing libc++
   headers entirely on the original dev machine. Install Xcode from the App Store:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license
   ```
   Both require an interactive human (sudo password, license text) — Claude Code
   cannot do this step.
2. **cmake** on PATH (Homebrew was broken on the original machine; `pip install --user
   cmake` worked as a substitute — use whatever works on the new machine).
3. **Clone/pull the repo, then init the submodule:**
   ```
   git submodule update --init --recursive
   ```
   Vendored whisper.cpp lives at `Vendor/whisper.cpp`, pinned to tag `v1.9.2`.
4. **Build whisper.cpp itself** (a separate CMake project, not part of `swift build`):
   ```
   cd Vendor/whisper.cpp
   cmake -B build -DGGML_METAL=ON -DGGML_BLAS_DEFAULT=ON -DBUILD_SHARED_LIBS=OFF \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
   cmake --build build --config Release
   cd ../..
   ```
   `Package.swift`'s linker `-L` flags expect libs at exactly these paths (verified
   against a real build output — ggml-blas and ggml-metal land in their own
   subdirectories, not directly under `ggml/src/`):
   ```
   Vendor/whisper.cpp/build/src              (libwhisper)
   Vendor/whisper.cpp/build/ggml/src         (libggml, libggml-base, libggml-cpu)
   Vendor/whisper.cpp/build/ggml/src/ggml-metal
   Vendor/whisper.cpp/build/ggml/src/ggml-blas
   ```
   If a new machine's `cmake --build` output puts these libs somewhere else,
   `Package.swift`'s `unsafeFlags` need updating to match.
5. **Download the Whisper model** (gitignored — `.gitignore` excludes
   `Vendor/whisper.cpp/models/*.bin`):
   ```
   cd Vendor/whisper.cpp/models && ./download-ggml-model.sh small.en && cd ../../..
   ```
   `small.en` was explicitly chosen (not base.en or medium.en).
6. **Verify the CWhisper header symlinks came through.** `Sources/CWhisper/include/`
   contains real symlinks pointing into the vendored submodule (e.g.
   `whisper.h -> ../../../Vendor/whisper.cpp/include/whisper.h`) — committed to git,
   should survive clone/pull, but confirm with `ls -la Sources/CWhisper/include/`.
   `cSettings.headerSearchPath` does NOT work for module-map header resolution in this
   SPM setup — don't re-try that approach.
7. **Build and test:**
   ```
   swift build
   swift test
   ```
   All 33 tests pass as of this save. `WhisperTranscriberTests.testTranscribesKnownSampleAudio`
   `XCTSkip`s cleanly if the model/sample audio aren't present yet. Ollama tests
   (`OllamaClientTests`, `OllamaServerManagerTests`) use stubbed/pure seams, not a
   live server, so they pass even before Ollama is installed.
8. **Grant macOS permissions** (GUI-only, cannot be scripted): Microphone (prompted
   automatically) and **Screen & System Audio Recording** (TCC-gated purely through
   System Settings — app opens the right pane, but you click Allow, then relaunch;
   macOS requires a relaunch after granting this specific permission).
9. **Install Ollama for Phase 2 summarization.** `brew install ollama` failed on the
   original dev machine two independent ways (Homebrew prefix ownership, and a
   Homebrew-core crash on macOS 26.4.1 unrelated to ownership) — **download
   Ollama.app directly from ollama.com/download instead** (drag-to-Applications, no
   sudo). The app doesn't need to be launched via the GUI — `OllamaServerManager`
   (see below) launches `ollama serve` itself directly from the `.app` bundle's
   `Contents/Resources/ollama` binary. Pull the model once manually to prime the
   local cache (the app doesn't auto-pull yet):
   ```
   /Applications/Ollama.app/Contents/Resources/ollama serve &   # or let the app manage this
   /Applications/Ollama.app/Contents/Resources/ollama pull llama3.1:8b
   ```
   `llama3.1:8b` (~4.9GB) is the model currently hardcoded as `OllamaClient`'s default
   — chosen over the design doc's other candidate (Qwen2.5 7B) as the first pick to
   prototype with; never formally benchmarked against it.

### Architecture decisions locked and built (Phase 1 — not up for debate; re-litigating these was explicitly declined during the original eng review)

- **Storage location:** `~/Documents/MeetingNoteTaker`, not `~/Library/Application
  Support`. Recommended against twice and explicitly overridden by the user both times
  for Finder discoverability — a formally **accepted risk**, logged in `TODOS.md`
  under "Accepted risk: iCloud-exclusion silent-failure mode." `StorageLocation.swift`
  self-heals the iCloud-exclusion flag on every launch as mitigation.
- **Audio capture:** single unified `SCStreamConfiguration` (`capturesAudio = true` +
  `captureMicrophone = true` together), not ScreenCaptureKit + a separate
  `AVAudioEngine` mic tap — avoids cross-stream clock drift over a long recording.
- **Transcription:** vendored whisper.cpp, `small.en` model, **CPU-only inference**
  (`contextParams.use_gpu = false` in `WhisperTranscriber.swift`). Metal GPU produced
  garbled output on the original dev machine's discrete AMD GPU (Radeon Pro 5300M,
  Intel Mac) — confirmed via a real test against whisper.cpp's `jfk.wav` sample.
  **May be Intel+AMD-GPU-specific.** If running on Apple Silicon, worth re-testing:
  flip `use_gpu = true`, re-run `WhisperTranscriberTests.testTranscribesKnownSampleAudio`.
  Tracked in `TODOS.md` ("Re-test Metal GPU acceleration on Apple Silicon").
- **Reasoning/summarization (Phase 2):** fully local via Ollama (design-doc "Approach
  A"), chosen over sending transcript text to a hosted API — strict local-only privacy
  over output quality. Accepted fallback if local model quality proves unusable: a
  per-meeting, explicitly opt-in Claude API call, never default-on.
- **No background daemon / queue system.** Sequential CLI pipeline (record →
  transcribe → store, one meeting at a time via `readLine()` prompts). Retention
  pruning (below) only runs when the app happens to launch — there's no scheduler.
- **SQLite via raw C API** (`import SQLite3`), not a wrapper library.
- Gmail follow-ups: **draft-only, never auto-send** (hard default). Calendar
  write-back now mirrors this (see below).

### Phase 1 hardening pass — IMPLEMENTED, TESTED, ALL 22 TESTS PASS (2026-08-10)

This ran through a full `/plan-eng-review` including an outside-voice (independent
Claude subagent — Codex CLI wasn't installed on the dev machine) cross-model review
that found 6 real problems with the initial plan. All 6 were resolved with the user
via individual approvals before implementation. What actually shipped:

**Encryption at rest → FileVault-only.** No app-layer encryption (no SQLCipher, no
custom AES/Keychain key management) — v1's realistic threat model (lost/stolen
*powered-off* laptop) is already covered by FileVault. `StorageLocation.isFileVaultEnabled()`
shells out to `fdesetup status`; `StorageLocation.parseFileVaultStatus(_:)` is the pure,
tested parser (fail-closed: unrecognized output → treated as disabled). `run()` warns
and continues if FileVault is off — never blocks launch, matching the iCloud-exclusion
precedent. TODOS.md "Encryption at rest" entry updated to record this as resolved.

**Data retention → 7-day auto-delete of raw audio, transcripts kept forever.**
`Meeting.audioDeletedAt: Date?` is the new schema field (kept `audioFilePath` as a
historical record rather than nulling it out). `MeetingStore.deleteExpiredAudio(now:)`
runs once at the top of `run()`, before the interactive recording prompt — this
required moving `MeetingStore()` construction from the end of `run()` to the start,
and reusing that one instance for both the startup prune and the later insert (was
previously constructed twice). A `retain_until` index was added alongside the existing
`started_at` index. **The outside voice's real find here:** a `Meeting` row used to
only get inserted after successful transcription — audio that failed to transcribe
(missing model) got no row, no `retainUntil`, and was permanently exempt from
retention. Fixed by moving the insert to immediately after recording stops, before
transcription is attempted; `updateTranscript()` fills in the text later if
transcription succeeds. TODOS.md "Data retention / deletion policy" entry updated.
**Known limitation, accepted for this pass:** there's still no list/browse command
anywhere in the CLI (`allMeetings()` is only called from tests) — audio gets deleted
with no way to review it first. The outside voice recommended deferring the whole
implementation until a browse command exists; the user explicitly chose to build it
now anyway. Worth building a browse/list command before this policy runs unattended
for long stretches.

**DB migration.** `MeetingStore.createSchemaIfNeeded()` only ever did
`CREATE TABLE IF NOT EXISTS`, which does nothing to a database that already exists —
every real Phase 1 install. `migrateAddAudioDeletedAtColumnIfNeeded()` now checks
`PRAGMA table_info(meetings)` and runs `ALTER TABLE ... ADD COLUMN audio_deleted_at REAL`
if missing. Covered by `MeetingStoreTests.testOpeningPreExistingPhase1DatabaseMigratesWithoutCrashing`,
which builds a real pre-migration fixture via raw SQLite (not via MeetingStore) to
verify against.

**Speaker diarization → still deferred, now with a real gate.** whisper.cpp's
experimental `tinydiarize` (`-tdrz`) was evaluated and rejected — it only detects
speaker-turn changes, not verified identity, so labels drift once a 3rd+ speaker
re-enters a conversation. User chose to keep researching a proper speaker-identity
approach instead (e.g. a local pyannote-based sidecar). **Milestone gate (not a
date):** must be decided — real diarization, or an explicit "ship Phase 2 unattributed"
fallback — before the first line of Ollama action-item extraction code is written.
This was chosen deliberately over a calendar deadline after the outside voice flagged
that open-ended "keep researching" risks never actually resolving. TODOS.md entry
updated with the full finding and the gate.

**MCP server auth model (Phase 2, not built yet) → locked to Unix domain socket**,
file-permission scoped to the user's account, not a TCP port with a bearer token.
TODOS.md entry updated to record the direction so Phase 2 doesn't re-litigate it.

**Google Calendar write-back (Phase 2, not built yet) → requires per-item
confirmation** before creating an event from an extracted action item, mirroring the
already-locked Gmail draft-only default. Not yet in TODOS.md as its own entry —
recorded here and in this session's history; add one before Phase 2 Calendar work
starts if it isn't already there.

**Code-quality fixes (all implemented, all tested):**
- `AudioRecorder.swift`: `write()` used to silently swallow errors via `try?`
  (disk-full mid-recording → silent truncation). Now tracks `lastError`, surfaced by
  `stopRecording()` throwing `RecorderError.captureFailed(underlying:)`.
- `didStopWithError` (unexpected stream stop, e.g. mic unplugged) used to only set
  `isRecording = false`. Now stores the real error and nils `stream`/`audioFile`/
  `currentSession`; a later `stopRecording()` call surfaces the real cause instead of
  a generic `.notRecording`.
- New `AudioFileWriting` protocol (narrow seam around `AVAudioFile.write(from:)`,
  `AVAudioFile` conforms structurally) injected via `AudioRecorder.audioFile`, so the
  write-error path is unit-testable with a throwing double.
- New `AudioRecorder.finalizeCaptureError(_:)` static pure function — the
  throw-decision extracted so it's testable with no `AudioRecorder` instance or live
  `SCStream` at all (the outside voice flagged that the original plan named an
  untestable test; this is how it got resolved).
- `PermissionManager.mapAuthorizationStatus(_:)` extracted as a pure function so the
  `AVAuthorizationStatus` → `RecordingPermissionStatus` mapping has direct test
  coverage instead of being coupled to a live TCC call.

**Tests added:** `PermissionManagerTests.swift`, `StorageLocationTests.swift`,
`AudioRecorderTests.swift` (all new), plus 5 new cases in `MeetingStoreTests.swift`
(retention pruning: expired/not-yet-expired/idempotent/missing-file, plus the legacy
migration test). 22 tests total, all passing, including the pre-existing real
end-to-end `WhisperTranscriberTests` case.

### Phase 2 progress — Ollama summarization IMPLEMENTED, TESTED (2026-08-10)

Ollama was installed via direct `.app` download (Homebrew stayed broken — see setup
step 9 above). Before writing any integration code, a real finding surfaced: Ollama
0.32.7 has an optional cloud-inference feature (`OLLAMA_REMOTES:[ollama.com]`,
"Ollama cloud disabled: false" by default in the server logs) that routes some model
calls off-device — directly at odds with this project's local-only premise, and not
something the original design doc anticipated. Resolved with the user via
AskUserQuestion before building anything (see TODOS.md "Resolved: Ollama
cloud-inference lockout" for the full writeup):

- **`OllamaServerManager`** (`Sources/MeetingNoteTaker/Summarization/OllamaServerManager.swift`)
  — launches `ollama serve` itself with `OLLAMA_NO_CLOUD=true` forced into the
  environment, rather than trusting a separately-launched Ollama.app instance. Verified
  live: `Ollama cloud disabled: true` in the server's own log output when launched this
  way. `ensureRunning()` returns `.launchedManaged` when it started the server itself,
  or `.reusedExisting` if a server was already listening on 11434 — the latter case
  can't be verified as cloud-disabled (no API for that), so callers must warn rather
  than silently trust it. `resolveBinaryPath(_:fileExists:)` and
  `managedEnvironment(base:)` are pure, tested seams; process-spawning and HTTP
  reachability polling are integration-level, manually verified rather than unit
  tested (same tradeoff as `AudioRecorder`'s live-ScreenCaptureKit parts).
- **`OllamaClient`** (`Sources/MeetingNoteTaker/Summarization/OllamaClient.swift`) —
  talks to `POST /api/generate` on `127.0.0.1:11434` only. `HTTPRequesting` protocol
  (structurally satisfied by `URLSession`, same pattern as `AudioFileWriting`) makes
  `summarize(transcript:)` unit-testable with a stubbed response instead of a live
  server. `buildSummaryPrompt(transcript:)` is a separately tested pure function.
- **`MeetingStore`**: added `summaryText: String?` (defaults to `nil` in the struct so
  existing call sites didn't need touching) and `updateSummary(meetingID:summary:)`.
  The single-column migration helper from the hardening pass was generalized into
  `ensureColumnExists(_:type:)` so adding `summary_text` didn't duplicate the
  `audio_deleted_at` migration pattern — now called for both columns.
- **Wired into `run()`**: after a transcript is saved, `summarize(meetingID:transcript:store:)`
  calls `OllamaServerManager.ensureRunning()` then `OllamaClient().summarize(transcript:)`,
  storing the result via `updateSummary`. **Best-effort, like the missing-Whisper-model
  path**: if Ollama isn't available or summarization fails for any reason, it prints a
  message and returns without throwing — the transcript that already saved
  successfully is never lost over a summarization failure.
- Manually verified end-to-end against the real running server via `curl` before
  writing the Swift wrapper (confirmed `llama3.1:8b` produces a sane summary from a
  sample transcript) — the full `run()` → summarize path itself has NOT been
  interactively tested yet (needs a real recording, same limitation as Phase 1's
  interactive testing).

**Tests added:** `OllamaClientTests.swift`, `OllamaServerManagerTests.swift` (both
new). 33 tests total, all passing.

**Not yet done from the design doc's Ollama step:** benchmarking `llama3.1:8b` against
Qwen2.5 7B for quality, and action-item extraction (separate from summarization) —
still gated on the diarization decision below.

### Meetings browse/list command — IMPLEMENTED, TESTED (2026-08-11)

Closes the retention-visibility gap accepted during the hardening pass. New CLI
subcommands, dispatched in `main()` before any of `run()`'s permission/recording setup
(so browsing never triggers mic/screen-recording prompts):
- `meetingnotetaker list` — numbered (1..N, most-recent-first, matches `allMeetings()`
  ordering), shows date, duration, audio retention status ("audio kept, deletes in Nd" /
  "audio deleted" / "audio kept (deletion pending...)"), and an 80-char transcript +
  summary preview.
- `meetingnotetaker show <number>` — full transcript + summary for one meeting, using
  the number from `list` output (not a UUID — friendlier to type). Out-of-range numbers
  print a usage hint instead of crashing.

All formatting logic (`MeetingBrowser.swift`) is pure and unit-tested — `audioStatus`,
`preview`, `durationString`, `daysUntilExpiry`, plus a bounds-safety test for `show`
with an empty list / index 0 / an index past the end.

**Real bug found and fixed while manually verifying this against the actual local
database:** `MeetingStoreTests.testInsertAndFetchMeeting` and `testUpdateTranscriptPersists`
were calling `try MeetingStore()` — which opens the **real** `~/Documents/MeetingNoteTaker/meetings.sqlite3`,
not an isolated test database like the 5 retention tests added during the hardening
pass (which correctly use `makeTempStore()`). Every `swift test` run had been silently
inserting fake "hello world" meetings into the real database — invisible until this
browse command made it visible. Fixed both tests to use `makeTempStore()`; confirmed
`swift test` no longer touches the real DB (row count unchanged before/after a test
run). **The real database had 12 junk rows from past test runs — deleted after explicit
confirmation**, keeping the one genuine recording from Phase 1's end-to-end verification.

**Tests added:** `MeetingBrowserTests.swift` (new). 45 tests total, all passing.

### MCP server — IMPLEMENTED, TESTED, VERIFIED LIVE (2026-08-11)

**Course correction before building anything:** the hardening pass had locked "Unix
domain socket, file-permission scoped" as the MCP auth model, based on a threat model
(any local process could connect to a persistent daemon) that turned out not to apply.
Verified against Claude Desktop's own docs: local MCP servers are **stdio-launched
subprocesses only** — Claude spawns the binary itself and talks over that process's own
stdin/stdout, which no other process can attach to at all. Stronger guarantee than a
socket file, and needs no auth design of its own. TODOS.md's "MCP server auth model"
entry records this as a reversed decision, not a silent swap — see it for the full
reasoning. This is exactly the kind of premise-check that's worth doing before writing
code, not after.

Built on the **official Swift MCP SDK** (`github.com/modelcontextprotocol/swift-sdk`,
added as a Package.swift dependency, product `MCP`) rather than hand-rolling JSON-RPC —
verified its API against the actual repo source (README + `Sources/MCP/Server/Tools.swift`)
before writing code, not guessed.

- **New subcommand: `meetingnotetaker mcp-serve`** — dispatched in `main()` alongside
  `list`/`show`. Not meant to be run interactively; a client launches it and talks MCP
  over its stdio.
- **`MCPServer.swift`** registers three tools against the existing `MeetingStore` (no
  new storage, reads what the recording pipeline already writes):
  - `search_meetings(query?)` — case-insensitive substring match across transcripts
    and summaries; omit query to list everything. Reuses `MeetingBrowser.listLine` for
    formatting (DRY with the `list` CLI command).
  - `get_transcript(meetingIndex)` / `get_summary(meetingIndex)` — full text by the
    1-based index from the most recent `search_meetings` call (same friendly-numbering
    convention as `show <n>`, not a UUID).
  - **`get_action_items` is deliberately NOT exposed** — action-item extraction doesn't
    exist yet, still gated on the diarization decision (see below).
- All tool logic (`searchMeetings`, `transcript`, `summary`, `meetingIndex` parsing) is
  pure and unit-tested against a temp `MeetingStore` — no live MCP transport needed for
  test coverage. `MeetingStore` was marked `@unchecked Sendable` (single-threaded
  access in practice: the sequential recording pipeline and MCP's one-client stdio
  handler never call it concurrently) to satisfy Swift 6 strict concurrency in the
  `@Sendable` tool-call closure.
- **Manually verified live**, not just unit tests: piped a real MCP JSON-RPC handshake
  (`initialize` → `notifications/initialized` → `tools/list` → `tools/call
  search_meetings`) into the built binary's `mcp-serve` subcommand over stdin.
  `tools/list` returned all 3 tools with correct schemas; `search_meetings` correctly
  returned the one real meeting in the database. Full transcript of that verification
  run is in this session's history if it needs re-checking.

**To actually connect Claude Desktop or Claude Code to this**, add to
`claude_desktop_config.json` (Desktop) or the equivalent Claude Code MCP config:
```json
{
  "mcpServers": {
    "meetingnotetaker": {
      "command": "/Users/SaiKasam/meetingnotetaker/.build/debug/MeetingNoteTaker",
      "args": ["mcp-serve"]
    }
  }
}
```
(Use a release build's path once one exists — `swift build -c release`.) **This
config step has NOT been done yet** — the server works when driven manually, but no one
has pointed an actual Claude client at it.

**Tests added:** `MCPServerTests.swift` (new), plus `TestSupport.swift` extracting the
temp-store helper that both `MeetingStoreTests` and `MCPServerTests` now share (was
duplicated `private` inside `MeetingStoreTests` before). 59 tests total, all passing.

### Remaining Work (Phase 2)

1. **Diarization decision is gated** — resolve it (real approach, or explicit
   unattributed fallback) before writing any Ollama action-item extraction code.
   Summarization (done above) didn't need this; action-item extraction does, and so
   does exposing `get_action_items` from the MCP server.
2. Benchmark `llama3.1:8b` vs Qwen2.5 7B on real transcripts — never done, design doc
   flagged as needed.
3. Actually configure a Claude client (Desktop or Code) to launch the MCP server (see
   config snippet above) and confirm it works from inside a real Claude conversation,
   not just a manual stdio test.
4. Google Calendar OAuth + event creation, gated on per-item confirmation (locked
   this session — add a TODOS.md entry for it if one doesn't exist yet).
5. Gmail OAuth + draft creation for follow-ups (draft-only, never auto-send — already
   locked).
6. The real UI, replacing the `readLine()`-based CLI — explicitly scoped into Phase 2,
   not before.
7. Interactively test the full record → transcribe → summarize flow end-to-end against
   a real meeting — only the summarization HTTP call has been verified live so far
   (via curl), not the wired `run()` path.

### Notes

- `TODOS.md` in the repo root is committed and transfers via git normally. All entries
  touched this session (diarization, encryption, MCP auth, retention, Ollama cloud
  lockout) were updated with the actual decisions and rationale, not just left as open
  questions — read it before making related changes.
- **Every commit gets pushed to `origin` (`https://github.com/SaiKasam159/meetingnotetaker.git`)
  immediately** — this is now standing practice for this project, not a one-off. `main`
  tracks `origin/main` directly; check `git status -sb` before pushing to confirm no
  divergence.
- Nothing is currently uncommitted on `main`.
- This project uses the gstack skill framework (routing rules in the repo's
  `CLAUDE.md`). `/plan-eng-review` was used for the hardening pass. If gstack isn't
  available on a new machine, the substance in this document doesn't require the
  skill tooling to act on.
- **Test isolation matters in this codebase.** `MeetingStoreTests` learned the hard way
  that `try MeetingStore()` opens the real on-disk database — always use
  `makeTempStore()` (defined in that file) for anything that inserts data, unless a
  test is deliberately exercising the real-path convenience initializer.
