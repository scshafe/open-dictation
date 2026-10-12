# Architecture

## Module map

- **OpenDictationCore** (`Sources/OpenDictationCore`): all testable logic.
  No SwiftUI; AppKit-free except through injected protocols. Owns the session
  state machine, audio capture/conversion, provider boundary, destination and
  insertion policy, settings/Keychain models, and temp-file lifecycle.
- **OpenDictationApp** (`Sources/OpenDictationApp`): SwiftUI views, AppKit
  integration (menu bar, main window, nonactivating panel), Carbon global
  shortcut, and the AX/pasteboard backends behind Core protocols.
- **OpenDictationTestSupport**: fakes shared by both runners.
- **Runners**: `Tests/OpenDictationCoreTests` (XCTest, Xcode hosts) and
  `Sources/OpenDictationSelfTest` (`swift run`, CLT-only hosts).

## Session ownership

`SessionCoordinator` (Core, `@MainActor`, `ObservableObject`) is the single
owner of session state. Phases: `idle → preparing → recording →
transcribing → resultReady → inserting → completed`, with `canceled` and
`failed` exits; `SessionTransition.isAllowed` encodes the legal table and
cleanup lives in the coordinator (idempotent cancel/discard).

Every session has a UUID, and the coordinator holds a `generation` counter
bumped on every start/cancel/retry/discard. Async continuations capture
(sessionID, generation) and bail out on mismatch, so a canceled or superseded
session can never insert text from a delayed callback, and a new recording
never receives an old transcript, error, or insertion outcome.

Provider configuration is snapshotted per session: editing Settings mid-flight
never mutates an in-flight request. Explicit Retry deliberately re-snapshots
current settings so the user can fix the URL/token first (documented in UI).

Uncommitted transcripts are never erased by starting another recording: the
previous session moves to `retainedSessions` (cap 10, session-only, never
written to disk). Quitting the app discards retained results and deletes
temp audio; abandoned temp files are cleaned on next launch.

Stop vs Cancel is semantic: Stop finalizes capture (synchronously releasing
the mic) and requests a transcript; Cancel discards everything and guarantees
no late insertion. Double-stop is a no-op.

## Audio flow

`AudioRecorder` (AVAudioEngine): the realtime tap copies buffers into a
bounded queue (256, overload reported + dropped, never unbounded) drained by
a serial writer; only a cheap RMS level runs inline. Duration comes from
frames written. A visible minutes-scale limit stops the recording with a
message — never a silence cutoff, never silent truncation.

Writes never convert: tap buffers are converted in memory to the exact file
format (interleaved Float32, `AudioBufferConvert`, unit-tested without a mic)
before `AVAudioFile.write`. This routes around verified macOS 26
AudioToolbox behavior where write-path conversion silently truncates
>4096-frame writes and aborts on int16→float32. The capture file's processing
format is pinned to that same interleaved format when it is opened and
verified (`AudioRecorder.makeCaptureFile`, regression-tested for mono and
stereo): the two-argument `AVAudioFile` initializer picks a deinterleaved
format for multi-channel input, which rejects every interleaved write.

`AudioFileConverter` runs offline after stop: pull-pattern `AVAudioConverter`
streams the capture (one chunk in flight) into Int16 samples, then the pure
`WAVFile` writer emits mono 16-bit PCM @ 16 kHz, verified by re-parsing the
header (rate/channels/bits/duration). Resampling is real; rates are never
relabeled. Input length is sanity-bounded; over-long/corrupt captures throw.

Temp lifecycle (`TempAudioStore`): capture deleted after conversion; upload
WAV deleted after success/cancel/dismissal, retained ONLY while a failed
session is retryable. No recording archives, no audio/transcripts in logs.

## Endpoint contract

`TranscriptionProvider` is the whole boundary: `transcribe(audioURL:config)
async throws -> TranscriptResult`. `HTTPTranscriptionAdapter` (URLSession,
ephemeral, no disk cache) implements the documented multipart contract —
exact user URL, `file` part (`recording.wav`, `audio/wav`), conditional
`model`/`language`, conditional bearer auth, `{"text": …}` success parsing
with malformed-vs-empty distinction. `FakeProvider` is deterministic for UI
exercise and tests.

Transport: configurable request/resource timeouts, bounded response (1 MB),
classified errors (transport/timeout/auth/rate-limit/unsupported/server/
malformed/empty/redirect/size/cancelled), no automatic retries, and a
redirect guard that follows same-origin redirects (scheme + host + effective
port) but refuses cross-origin ones so credentials and audio are never
forwarded; a refused redirect reaches the adapter as a 3xx and is classified
as `redirectBlocked`. Server error bodies are
never surfaced as transcripts. TLS uses ordinary system validation; local
plain-HTTP works without shipped exceptions.

A streaming provider later adds a second protocol with partial/final events;
batch callers stay unchanged.

## Destination tracking and focus behavior

`DestinationService` is captured BEFORE the panel appears: pid, bundle id,
window identity (the window server's window number, matched by bounds through
the public CGWindowList API — never the title, which changes constantly in
terminals, browsers, chat apps and editors; a role+bounds hash is the fallback
when the match is not unique), focused role/identifier, selection text + range, and a fingerprint of the
character count plus a 200-character prefix read through the
string-for-range attribute. The full value, documents, and screen contents are
never read; secure fields are detected and refused.

`DestinationPolicy.validate` re-checks immediately before insertion. Any app/
window/field/caret/selection/content change — or any uncertainty (target
gone, unreadable) — refuses automatic insertion and keeps the transcript.
Focus-away-and-back does not imply survival. The validate→insert race is
minimized, documented, and never claimed atomic.

The floating panel is an `NSPanel` with `.nonactivatingPanel` (+ utility,
floating level, all-Spaces/full-screen-auxiliary), `canBecomeKey` for
clickable Stop/Cancel without activation, clamped to the visible frame of the
display with the mouse. Every presentation records a focus check (frontmost
app before/after, whether the app activated) for the manual verification
procedure. Opening the main editor invalidates pending auto-insert.

## Insertion: correctness before convenience

Modes: **Insert automatically when safe** (one attempt, only after
revalidation) and **Review/copy** (never). Exactly-once per attempt is
enforced by phase (`inserting` in flight refuses concurrent attempts) and by
never re-pasting after ambiguous outcomes.

Order: targeted Accessibility write first — sets `kAXSelectedText` (replaces
the selection exactly like typing; the full value is never replaced) after
checking writability. Success is confirmed by any one of three read-back
signals (`InsertionConfirmation`, unit-tested): the selection still equals the
transcript, a bounded string-for-range read of the inserted range equals it,
or a zero-length selection sits exactly after it (AppKit text views collapse
the selection to a caret). No signal → `uncertain`. Outcomes distinguish
`inserted / skippedStale / unsupported / failed / uncertain /
permissionMissing / deferredToReview`. Clipboard-and-paste runs ONLY after a
positive `.unsupported`; after `.failed`/`.uncertain` no paste follows, so a
transcript can never duplicate.

Paste fallback saves all pasteboard representations (bounded at 32 MB),
sends Cmd+V via CGEvent, then restores ONLY if the changeCount proves nobody
else touched the clipboard (`ClipboardPolicy`, tested). Otherwise the
transcript stays on the clipboard and the UI says so. Copy is always a
deliberate, non-restoring action. Secure input is never bypassed.

Permissions: microphone (recording), Accessibility (cross-app capture and
insertion). Input Monitoring and speech-recognition authorization are not
requested. The build is non-sandboxed (documented why) for direct
distribution; closing windows never stops the background shortcut.
