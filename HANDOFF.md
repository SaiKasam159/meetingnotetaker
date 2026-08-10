---
status: in-progress
branch: main
timestamp: 2026-08-10T19:58:00Z
files_modified: []
---

## Working on: meetingnotetaker — Phase 1 hardened, Phase 2 (Ollama/MCP/Calendar/Gmail) next

### Summary

meetingnotetaker is a local-first macOS replica of Granola: record meetings (mic +
system audio), transcribe locally via whisper.cpp, store everything on-disk, no cloud
except a narrow bounded exception for user-initiated Google Calendar/Gmail writes.
**Phase 1 is fully built, hardened, tested, and committed.** It was verified
end-to-end against a real recording (not just the test sample) before hardening
started, and the hardening pass below has been implemented and all 22 tests pass.
Phase 2 (Ollama summarization/action items, MCP server, Calendar/Gmail write-back, and
the real UI replacing the current `readLine()` CLI) has not started — this doc exists
so a fresh Claude Code session (this machine or another) can pick that up with full
context.

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
   All 22 tests pass as of this save. `WhisperTranscriberTests.testTranscribesKnownSampleAudio`
   `XCTSkip`s cleanly if the model/sample audio aren't present yet.
8. **Grant macOS permissions** (GUI-only, cannot be scripted): Microphone (prompted
   automatically) and **Screen & System Audio Recording** (TCC-gated purely through
   System Settings — app opens the right pane, but you click Allow, then relaunch;
   macOS requires a relaunch after granting this specific permission).

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

### Remaining Work (Phase 2 — none of this has started)

0. **BLOCKED on Ollama installation.** `brew install ollama` fails two independent
   ways on this machine: Homebrew's prefix at `/usr/local/Homebrew` isn't owned by the
   user account (`sudo chown -R SaiKasam /usr/local/Homebrew` would fix that one, but
   that's a sudo step for the human, same policy as the Xcode CLT setup earlier), and
   separately Homebrew's core crashes on macOS 26.4.1 (`macos_version.rb:42` doesn't
   recognize the version string) — a second, unrelated bug that fixing ownership alone
   won't resolve. **Recommended path: skip Homebrew entirely, download Ollama.app
   directly from ollama.com/download** (drag-to-Applications, no sudo, includes the
   `ollama` CLI). Once installed and running (`ollama serve`, or just launch the app),
   Phase 2 work can proceed. Check with `curl http://localhost:11434/api/version`.
1. **Diarization decision is gated** — resolve it (real approach, or explicit
   unattributed fallback) before writing any Ollama action-item extraction code.
2. Wire Ollama; prototype summarization/action-item extraction prompts against real
   transcripts. Benchmark model choice (design doc suggested Llama 3.1 8B or Qwen2.5 as
   starting candidates, never benchmarked). Summarization does NOT need the diarization
   decision — only action-item extraction (owner attribution) does — so summarization
   work can start as soon as Ollama itself is installed.
3. Build the MCP server — Unix domain socket auth (locked direction, see above), tool
   surface: `search_meetings`, `get_transcript`, `get_summary`, `get_action_items`
   (names proposed in the original design doc, not yet reconfirmed).
4. Google Calendar OAuth + event creation, gated on per-item confirmation (locked
   this session — add a TODOS.md entry for it if one doesn't exist yet).
5. Gmail OAuth + draft creation for follow-ups (draft-only, never auto-send — already
   locked).
6. The real UI, replacing the `readLine()`-based CLI — explicitly scoped into Phase 2,
   not before.
7. Consider building a meetings browse/list command sooner rather than later — the
   retention policy is now silently deleting audio with no way to review it first,
   which is a real limitation the outside voice flagged and the user knowingly accepted
   for this pass only.

### Notes

- `TODOS.md` in the repo root is committed and transfers via git normally. All entries
  touched this session (diarization, encryption, MCP auth, retention) were updated
  with the actual decisions and rationale, not just left as open questions — read it
  before making related changes.
- Nothing is currently uncommitted on `main`.
- This project uses the gstack skill framework (routing rules in the repo's
  `CLAUDE.md`). `/plan-eng-review` was used for this hardening pass. If gstack isn't
  available on a new machine, the substance in this document doesn't require the
  skill tooling to act on.
