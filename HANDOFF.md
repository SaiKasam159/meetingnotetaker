---
status: in-progress
branch: main
timestamp: 2026-08-10T08:23:51Z
files_modified: []
---

## Working on: Harden Phase 1, scope-lock Phase 2 (meetingnotetaker)

### Summary

meetingnotetaker is a local-first macOS replica of Granola: record meetings (mic +
system audio), transcribe locally via whisper.cpp, store everything on-disk, no cloud
except a narrow bounded exception for user-initiated Google Calendar/Gmail writes.
Phase 1 (capture + transcription + storage) is fully built, committed, and verified
end-to-end against a **real recording** (not just the test sample) — permissions,
transcription accuracy, and SQLite persistence all confirmed working by the user
directly. This session ran `/plan-eng-review` to harden Phase 1 before starting Phase 2
(Ollama summarization, MCP server, Calendar/Gmail write-back), with UI work (replacing
the current `readLine()`-based CLI) explicitly deferred into Phase 2 per the user's
direction. **The review is mid-flight and unfinished** — several real decisions got
locked in, then an independent second-opinion review (the "outside voice") found 6
concrete problems with the plan that were never walked through with the user before the
session ended. Nothing described in "Decisions Made" below has been implemented in code
yet — it's all still just decisions.

### Repo / environment this assumes

- Repo: `meetingnotetaker`, currently 2 commits on `main`, clean working tree.
  - `3acaa1b` Wire recorder, transcriber, and storage into the app entry point
  - `7ae50a3` Scaffold Phase 1: local audio capture, transcription, and storage
- This machine's `~/.gstack/projects/meetingnotetaker/` holds gstack review artifacts
  (design doc, test plan, tasks JSONL) that **do not travel with `git clone`/`git pull`**
  — they're local machine state, not repo content. This handoff doc inlines everything
  load-bearing from them so the new machine doesn't need that directory at all. If gstack
  artifact sync is configured on both machines it'll show up anyway, but don't rely on it.

### Toolchain setup required on the new machine (none of this is optional — Phase 1 will not build without all of it)

1. **Full Xcode.app, not just Command Line Tools.** CLT-only was missing libc++ headers
   entirely on this machine. Install Xcode from the App Store, then:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license
   ```
   (Both require an interactive human running them — sudo password + accepting the
   license text. Claude Code cannot do this step; the user has to.)
2. **cmake.** Homebrew was broken on this machine; installed via `pip install --user
   cmake` instead. Use whatever works on the new machine — just needs `cmake` on PATH.
3. **Clone/pull the repo, then init the submodule:**
   ```
   git submodule update --init --recursive
   ```
   Vendored whisper.cpp lives at `Vendor/whisper.cpp`, pinned to tag `v1.9.2`.
4. **Build whisper.cpp itself** (this is NOT part of `swift build` — it's a separate
   CMake project that produces static libs Package.swift links against):
   ```
   cd Vendor/whisper.cpp
   cmake -B build -DGGML_METAL=ON -DGGML_BLAS_DEFAULT=ON -DBUILD_SHARED_LIBS=OFF \
     -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
   cmake --build build --config Release
   cd ../..
   ```
   Package.swift's linker flags expect libs at exactly these paths (verified against a
   real build output on 2026-08-09 — ggml-blas and ggml-metal land in their own
   subdirectories, not directly under `ggml/src/`):
   ```
   Vendor/whisper.cpp/build/src              (libwhisper)
   Vendor/whisper.cpp/build/ggml/src         (libggml, libggml-base, libggml-cpu)
   Vendor/whisper.cpp/build/ggml/src/ggml-metal
   Vendor/whisper.cpp/build/ggml/src/ggml-blas
   ```
   If the new machine's `cmake --build` output ever puts these libs somewhere else,
   Package.swift's `unsafeFlags` `-L` paths need updating to match — don't assume the
   paths above are guaranteed stable across cmake/whisper.cpp versions.
5. **Download the Whisper model** (gitignored, not in the repo — `.gitignore` excludes
   `Vendor/whisper.cpp/models/*.bin`):
   ```
   cd Vendor/whisper.cpp/models
   ./download-ggml-model.sh small.en
   cd ../../..
   ```
   The user explicitly chose `small.en` as the model size (not base.en or medium.en).
6. **Verify the CWhisper header symlinks came through.** `Sources/CWhisper/include/`
   contains symlinks pointing back into the vendored submodule (`whisper.h` and every
   `ggml/include/*.h` it transitively includes) — e.g.
   `Sources/CWhisper/include/whisper.h -> ../../../Vendor/whisper.cpp/include/whisper.h`.
   These were created as real symlinks and committed to git, so `git clone`/`pull`
   should preserve them, but confirm with `ls -la Sources/CWhisper/include/` — if any
   show up as regular (broken) files instead of symlinks, re-create them manually.
   `cSettings.headerSearchPath` was tried first and does NOT work for module-map header
   resolution in this SPM setup — don't waste time re-trying that approach.
7. **Build and test:**
   ```
   swift build
   swift test
   ```
   `WhisperTranscriberTests.testTranscribesKnownSampleAudio` is a real end-to-end test
   against whisper.cpp's own `jfk.wav` sample — it `XCTSkip`s cleanly if the model or
   sample audio isn't present yet, so a missing model won't fail the build.
8. **Grant macOS permissions** (GUI-only, cannot be scripted or done by Claude Code):
   Microphone (prompted automatically on first `swift run`) and **Screen & System Audio
   Recording** (no code-signing entitlement exists for this — it's TCC-gated purely
   through System Settings; the app opens the right settings pane automatically but you
   have to click Allow yourself, then relaunch — macOS requires a relaunch after granting
   this specific permission, a first `swift run` won't pick it up mid-process).

### Architecture decisions already locked and built (Phase 1, not up for debate — re-litigating these was explicitly declined during the original eng review)

- **Storage location:** `~/Documents/MeetingNoteTaker`, not `~/Library/Application
  Support`. This was recommended against twice (original eng review, and again by an
  outside-voice cross-model review) and the user explicitly overrode both times for
  Finder discoverability. It's a formally **accepted risk** — logged in `TODOS.md` under
  "Accepted risk: iCloud-exclusion silent-failure mode." `StorageLocation.swift`
  self-heals the iCloud-exclusion flag on every launch as the mitigation. Do not
  re-propose switching this without the user raising it first.
- **Audio capture:** single unified `SCStreamConfiguration` with `capturesAudio = true`
  AND `captureMicrophone = true` together (one synchronized ScreenCaptureKit stream),
  not ScreenCaptureKit + a separate `AVAudioEngine` mic tap — avoids cross-stream clock
  drift over a long recording.
- **Transcription:** vendored whisper.cpp, `small.en` model, **CPU-only inference**
  (`contextParams.use_gpu = false` in `WhisperTranscriber.swift`). Metal GPU produced
  garbled output ("a" instead of real speech) on this machine's discrete AMD GPU (Radeon
  Pro 5300M, an older Intel Mac) — confirmed via a real test against whisper.cpp's own
  known-good `jfk.wav` sample; CPU + Accelerate/BLAS was proven correct by the same test.
  **This may be an Intel+AMD-GPU-specific bug, not a general whisper.cpp/Metal problem.**
  If the new machine is Apple Silicon, this is worth re-testing — flip `use_gpu = true`
  and re-run `WhisperTranscriberTests.testTranscribesKnownSampleAudio` to check. This is
  tracked as its own TODOS.md item ("Re-test Metal GPU acceleration on Apple Silicon").
- **Reasoning/summarization (Phase 2):** fully local via Ollama (design-doc "Approach
  A"), explicitly chosen over sending transcript text to a hosted API, prioritizing
  strict local-only privacy over output quality. If local model quality proves unusable
  for action-item extraction, the accepted fallback is a per-meeting, explicitly
  opt-in Claude API call — never default-on.
- **No background daemon / queue system.** The app is a sequential CLI pipeline
  (record → transcribe → store, one meeting at a time via `readLine()` prompts). This
  matters for the retention-pruning design below — there's no scheduler to hook into,
  only "whenever the app happens to launch next."
- **SQLite via raw C API** (`import SQLite3`, `.linkedLibrary("sqlite3")`), not a
  wrapper library — `SQLITE_TRANSIENT` destructor constant needed for `sqlite3_bind_text`.
- Gmail follow-ups are locked as **draft-only, never auto-send** (hard default, not a
  toggle) — this precedent is why the new Calendar-write decision below mirrors it.

### Decisions Made (this session — approved by the user via AskUserQuestion, NOT yet implemented in code)

**Encryption at rest:** FileVault-only, not app-layer encryption (no SQLCipher, no
custom AES/Keychain key management). Rationale: v1's threat model is a lost/stolen
*powered-off* laptop, which FileVault (AES-XTS, Secure Enclave-backed) already covers.
App-layer encryption would only add protection against another logged-in user on the
same machine or malware while logged in — neither is in scope for solo, single-Mac use.
`StorageLocation.isFileVaultEnabled()` (not yet written) should check `fdesetup status`
at every launch; if disabled, **warn and continue — do not block launch**, matching the
existing accepted-risk pattern already used for the iCloud-exclusion mitigation.

**Data retention:** auto-delete raw audio 7 days after successful transcription (grace
period so a bad transcript can still be re-run against the source audio). Transcripts
are kept indefinitely. `Meeting.retainUntil` (already an unused field in the schema) gets
set to `transcribedAt + 7 days` at insert time. A new `Meeting.audioDeletedAt: Date?`
field marks when audio was actually deleted — `audioFilePath` stays as a historical
record rather than being nulled out, so future code has one explicit field to check
instead of inferring deletion from a missing file. `MeetingStore.deleteExpiredAudio(now:)`
(not yet written) was meant to run once at app startup, before the interactive recording
prompt. **See "Outside-voice findings" below — this whole feature's readiness to be
built at all is now in question, findings #1, #3, #4, #5 all attack this specifically.**

**Speaker diarization:** explicitly held off, NOT built this pass. whisper.cpp has an
experimental "tinydiarize" model variant (`-tdrz`, already part of the vendored
submodule, no new dependency) that inserts speaker-turn-change tokens into transcript
output — but it only detects "someone new started talking," not verified speaker
*identity*, so labels can drift/misattribute once a 3rd+ speaker re-enters a
conversation. The user was offered tinydiarize as the recommended pragmatic v1 option
and explicitly declined it, choosing instead to hold off and research a proper
speaker-identity approach (e.g. a local pyannote-based sidecar process) before building
anything. **See outside-voice finding #6 — this deferral doesn't actually satisfy
Phase 2's own stated entry condition ("decide before Phase 2 extraction starts").**

**MCP server auth model (Phase 2, not built now):** locked direction — Unix domain
socket, file-permission scoped to the user's own account, not a TCP port with a bearer
token. No token generation/rotation to manage; the OS already enforces "only processes
running as you can connect."

**Google Calendar write-back default (Phase 2, not built now):** locked to require
per-item confirmation before creating a Calendar event from an extracted action item —
mirrors the already-locked Gmail draft-only default. Rationale: Approach A (fully local
via Ollama) already accepted lower extraction quality than a frontier model as a
deliberate privacy tradeoff; auto-writing to a real Calendar directly from that
extraction has real blast radius (wrong date, wrong inferred attendee) with no review
step.

**Code-quality fixes approved (not yet implemented):**
1. `AudioRecorder.swift:94` — `try? audioFile.write(from: pcmBuffer)` currently silently
   swallows write failures (e.g. disk full mid-recording → silent truncation, zero
   signal). Fix: track a `lastError` set on failure; `stopRecording()` checks it and
   throws a new `RecorderError.captureFailed(underlying:)` case after stopping capture.
2. `AudioRecorder.swift:106-113` — `didStopWithError` (fires when ScreenCaptureKit stops
   the stream unexpectedly, e.g. mic unplugged) currently only sets `isRecording = false`
   and never stores the real error or nils `stream`/`audioFile`/`currentSession`. Fix:
   store the error in the same slot as #1, clean up state, so a later `stopRecording()`
   call surfaces the real cause instead of a generic `.notRecording`.
3. `PermissionManager.checkMicrophonePermission()` couples a live `AVCaptureDevice` OS
   call with branching logic that has zero test coverage. Extract a pure
   `static func mapAuthorizationStatus(_ status: AVAuthorizationStatus) ->
   RecordingPermissionStatus` so the mapping is directly unit-testable.
4. New: `StorageLocation.parseFileVaultStatus(_ output: String) -> Bool` as a pure,
   testable parser for `fdesetup status` output — **fail-closed**: unrecognized/empty
   output should be treated as "off" (triggers the warning) rather than silently assumed
   protected.
5. New: a narrow `AudioFileWriting` protocol (`func write(from: AVAudioPCMBuffer) throws`)
   injected into `AudioRecorder`'s initializer, which `AVAudioFile` already conforms to
   structurally (defaulting to a real `AVAudioFile`-backed instance in production), so
   fix #1's error path can be tested with a throwing test double instead of needing a
   real disk-full condition. **See outside-voice finding #2 — this seam alone is not
   enough to test the full `stopRecording()` → `captureFailed` path; `stream`,
   `currentSession`, and `isRecording`'s setter are all `private` with no other seam.**

**Test plan approved (none written yet):**
- `PermissionManagerTests.swift` (new) — all 4 reachable `AVAuthorizationStatus` →
  `RecordingPermissionStatus` mappings via `mapAuthorizationStatus`.
- `StorageLocationTests.swift` (new) — `parseFileVaultStatus` for "On", "Off", and
  unexpected/empty output (fail-closed).
- `MeetingStoreTests.swift` (extend) — `deleteExpiredAudio`: expired+undeleted meeting
  gets pruned; not-yet-expired meeting untouched; already-deleted meeting skipped
  (idempotency); already-missing audio file on disk doesn't crash; opening a
  pre-existing Phase-1-era DB file (no `audio_deleted_at` column) migrates without
  crashing. **The last one is impossible as currently scoped — see outside-voice
  finding #1.**
- `AudioRecorderTests.swift` (new) — using the injectable `AudioFileWriting` double: a
  throwing writer sets `lastError`; `stopRecording()` throws `captureFailed` when
  `lastError` is set; `didStopWithError` clears `stream`/`audioFile`/`currentSession`
  state. **The `stopRecording()`/`captureFailed` half of this is impossible as currently
  scoped — see outside-voice finding #2.**

**Performance:** add a SQLite index on `retain_until` alongside the existing
`started_at` index (near-zero cost, avoids a full table scan on `deleteExpiredAudio`'s
query as meeting history grows over months/years of solo use).

### Outside-voice findings — UNRESOLVED, this is the most important thing to do next

An independent review (Claude subagent — Codex CLI wasn't installed on this machine, so
it fell back per gstack's outside-voice protocol) was run against the plan above and
found 6 concrete problems. **None of these were walked through with the user before the
session ended.** Per gstack's rule, outside-voice findings are informational until
individually presented via AskUserQuestion and approved/rejected by the user — do NOT
silently apply any of these fixes without asking first, and do NOT silently ignore them
either.

1. **[High] DB migration gap.** The plan promises a test for "opening a pre-existing
   Phase-1-era DB file (no `audio_deleted_at` column) migrates without crashing," but
   `MeetingStore.createSchemaIfNeeded()` only runs `CREATE TABLE IF NOT EXISTS`
   (`MeetingStore.swift:39-50`) — that never adds a column to a table that already
   exists. No `ALTER TABLE` / column-detection step was ever specified anywhere in the
   approved fix list. As scoped, this promised test cannot pass against the user's real
   existing local database (which already has rows from the verified Phase 1 test run).
2. **[High] An untestable test was approved.** The `AudioRecorderTests` plan calls for
   testing "`stopRecording()` throws `captureFailed` when `lastError` is set," but
   `stream`, `currentSession` are fully `private` and `isRecording` is `private(set)`
   (`AudioRecorder.swift:24-29`), with no injection seam besides the new
   `AudioFileWriting` protocol, which only covers the `write()` path. A test can't drive
   `stopRecording()` into that branch without live ScreenCaptureKit capture. Needs an
   access-control or additional-seam decision that wasn't made.
3. **[Medium] Sequencing was never actually wired.** The plan says
   `deleteExpiredAudio(now:)` runs "before the interactive recording prompt," but
   `MeetingStore()` is currently only constructed at the very end of `run()`
   (`MeetingNoteTakerApp.swift:104`), after transcription completes. Nothing in the
   approved fix list moves that construction earlier — as written, the feature has
   nowhere to actually hook in.
4. **[Medium-High] Retention has a silent blind spot.** When no Whisper model is found,
   `run()` returns before `store.insert()` is ever called (`MeetingNoteTakerApp.swift:
   86-89`) — that audio file gets no `Meeting` row, hence no `retainUntil`, and is
   permanently exempt from the 7-day deletion policy. The audio most likely to sit
   around indefinitely (never transcribed) is exactly the audio the retention system
   can't see.
5. **[Medium-High, STRATEGIC — resolve this one first, it reshapes the others.]**
   There is no list/browse command anywhere in the current CLI —
   `MeetingStore.allMeetings()` is only ever called from tests. The plan builds full
   retention machinery (schema field, index, startup job, idempotency tests) for a
   system that silently deletes files the user has no way to see or review first.
   The outside voice's recommendation: **defer the retention *implementation* the same
   way diarization got deferred** — record the policy decision in `TODOS.md` (already
   done for the *decision*, see above) but don't build the deletion machinery until
   there's a way to actually browse what's stored. If the user agrees with this, findings
   #1, #3, and #4 become moot for this pass (nothing to migrate/wire/blind-spot-fix if
   nothing gets built yet) — which is why this is the one to present first.
6. **[Medium] Diarization deferral doesn't actually unblock Phase 2.** `TODOS.md`
   states attribution must be decided "before Phase 2's Ollama-based action item
   extraction work starts" since extraction/write-back depend on it. This session's plan
   defers diarization to open-ended "research a proper approach" with no decision point
   — so the pass meant to precede Phase 2 leaves Phase 2's own stated entry condition
   unmet. Needs either a concrete research deadline/decision point, or an explicit
   "ship Phase 2 with unattributed action items for now" fallback decision.

### Remaining Work

1. **First: present outside-voice finding #5 to the user** (defer retention
   implementation entirely vs. build it now with fixes for #1/#3/#4) — this is the
   pivotal call that reshapes the rest of the plan.
2. Present findings #1, #2, #4, #6 individually via AskUserQuestion (one per call, per
   gstack's cross-model-tension protocol) — even if #5 resolves in favor of deferring,
   #2 and #6 are independent and still need resolving.
3. Resolve the interrupted TODOS.md update: the user backed out of (did not reject, just
   interrupted) a question about updating the "Speaker diarization" TODOS.md entry with
   the tinydiarize finding. This is still genuinely open — ask again once the outside-
   voice findings are cleared, don't assume either way.
4. Once findings are resolved, the `/plan-eng-review` skill still has these required
   outputs unfinished: Diagrams section, Failure modes section, Worktree parallelization
   strategy, Implementation Tasks (markdown + JSONL artifact for `/autoplan`), Completion
   summary, Review Log persistence (`gstack-review-log`), Review Readiness Dashboard,
   Next Steps chaining (offer `/plan-design-review` / `/plan-ceo-review` if applicable).
5. Only after the review is actually complete: implement the approved code-quality fixes
   and (whichever subset of) the retention/FileVault/diarization-TODO work survives step
   1-2, with tests, then re-verify `swift build && swift test` passes.
6. Longer-horizon (Phase 2, scope already locked, no code yet): Ollama integration for
   summarization/action-item extraction, MCP server (Unix-socket auth, per decisions
   above), Google Calendar OAuth + confirm-before-write, Gmail OAuth + draft-only
   write, and the real UI (replacing `readLine()`).

### Notes

- `TODOS.md` in the repo root is committed and will transfer via git normally — it
  currently has 7 entries: accepted iCloud risk, speaker diarization, data retention,
  remote-participant consent notification (manual verbal announcement required starting
  with the first real-meeting test — already in effect, printed every `run()`), re-test
  Metal GPU on Apple Silicon, MCP server auth model, encryption at rest. Read it before
  making changes — some of the decisions above should update it (see Remaining Work #3)
  but that update was never actually written.
- The design doc, test-plan artifact, and tasks JSONL from the original Phase 1 eng
  review live under `~/.gstack/projects/meetingnotetaker/` on **this** machine only —
  they do not transfer with `git clone`. Everything load-bearing from them is already
  inlined above (Approach A rationale, success criteria, locked precedents like the
  Gmail draft-only default). If deeper original context is ever needed and this machine
  is reachable, the design doc is at
  `~/.gstack/projects/meetingnotetaker/SaiKasam-unknown-design-20260809-154322.md`.
- This project uses the gstack skill framework (routing rules are in the repo's
  `CLAUDE.md`) — `/plan-eng-review` is the in-progress skill this session was running
  when it got interrupted. On the new machine, gstack needs to be installed/available
  for that skill to exist (`~/.claude/skills/gstack/`) — if it isn't, either install it
  or just continue the review manually using the state captured in this document; the
  substance (the 6 outside-voice findings, the locked decisions) doesn't require the
  skill tooling itself to act on.
- Nothing is currently uncommitted on `main` — working tree is clean as of this save.
