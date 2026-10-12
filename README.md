# Open Dictation

A native macOS app for system-wide dictation through a transcription endpoint
**you** configure — a local server, a LAN machine, or a remote service. No
account, subscription, telemetry, or Apple Dictation dependency.

Press the global shortcut (default **⌥⇧Space**) in any app, speak into the
floating panel, press the shortcut again — the transcript is inserted at your
cursor when the destination still validates, otherwise kept for review/copy.

The reusable **OpenDictationCore** Swift package provides the same recording,
transcription, session, and insertion-policy capabilities used by the app.
See [library integration](docs/LIBRARY.md) for installation and usage.

> Working name only; not a branding or trademark determination.

## Prerequisites

- macOS 14 or later (Apple Silicon primary target; no arch-specific code)
- Swift toolchain: full Xcode **or** Command Line Tools only
  (`swift --version` ≥ 5.9; developed with Swift 6.3.1, CLT-only host)
- Python 3 (stdlib only) for the mock transcription server
- A transcription endpoint reachable over HTTP(S) — or the bundled mock server

No third-party dependencies. No paid signing identity, notarization, or App
Store steps are needed for development.

## Build, run, test

```sh
# 1. Build everything (library + app + self-test runner)
swift build

# 2. Run the dependency-free checks (works with CLT-only toolchains)
swift run OpenDictationSelfTest
# -> selftest: 161 checks, 0 failures

# 3. Start the mock transcription server (deterministic, clearly labeled output)
./scripts/run-mock-server.sh --port 8080

# 4. Live integration: real HTTP adapter -> real mock server
swift run OpenDictationSelfTest --live-mock http://127.0.0.1:8080

# 5. Package a launchable .app (REQUIRED for mic/Accessibility: permissions
#    need a bundle id + Info.plist usage description + stable signing)
./scripts/package-app.sh release   # or: debug
open .build/OpenDictation.app
```

On Xcode hosts, the canonical suite also runs as XCTest:

```sh
swift test        # needs Xcode's XCTest; CLT-only hosts lack that module
```

`swift test` and `swift run OpenDictationSelfTest` cover the same behaviors
(session transitions, stale/cancel races, exactly-once insertion, multipart
contract, response classification, WAV validity + real resample, destination
refusal, clipboard policy, cleanup). Fakes are shared in
`Sources/OpenDictationTestSupport`.

## Endpoint setup

Open Settings in the app and enter the **full request URL including the path**,
e.g. `http://127.0.0.1:8080/v1/audio/transcriptions`. The app sends exactly
what you configure — it never guesses or appends paths.

The adapter implements this multipart contract (OpenAI-style subset):

- `POST` multipart/form-data to your URL
- `file` part: the recording (`recording.wav`, `audio/wav`, mono 16-bit PCM
  16 kHz — really resampled, never relabeled)
- `model` field: only when set · `language` field: only when set
- `Authorization: Bearer …`: only when a token is saved (Keychain)
- Success: JSON with a string `text` field

Non-secret examples live in `tools/example-config.json`. Verify field names
against your server build — "OpenAI-compatible" servers differ in practice.

### Example: Open WebUI's built-in transcription (e.g. over Tailscale)

Open WebUI exposes its embedded speech-to-text backend (faster-whisper by
default) at `POST <base>/api/v1/audio/transcriptions`, and it speaks this
exact contract: `file` part, optional `language`, no `model` field (the model
is chosen server-side), `{"text": …}` reply. It requires an authenticated
user: save an Open WebUI API key (or session token) as the bearer token in
Settings — non-admin users also need the `chat.stt` permission. Use generous
timeouts for CPU transcription (e.g. 300 s request / 900 s resource). Tailnet
or LAN reachability alone never bypasses application authentication.

Verify authentication and real recognition with a short non-sensitive clip.
The token is read from the app's Keychain entry and is never printed:

```sh
say -v Samantha -o clip.wav --file-format=WAVE --data-format=LEI16@16000 "Open Dictation test clip."
# (name a voice explicitly: with a missing default voice `say` writes a silent file)
swift run OpenDictationSelfTest --live-endpoint app --clip clip.wav
# `app` uses the endpoint/language/timeouts saved in the app's Settings;
# pass a full URL instead of `app` to try another server.
```

The Settings tab's test-tone button reports success when a real recognizer
returns an empty transcript for the tone — that proves transport and
authentication; use the clip command (or just dictate) to see real text.

### Local HTTP endpoints

Plain `http://` URLs work for localhost/LAN development (macOS App Transport
Security permits local networking; no exception is shipped). For remote
servers prefer HTTPS with ordinary system certificate validation — the app
never disables TLS verification and refuses cross-origin redirects so tokens
and audio can't be silently forwarded elsewhere.

## Permissions

| Feature | Permission | Notes |
|---|---|---|
| Recording | Microphone | Asked on first Record/shortcut (user-initiated). Info.plist carries the usage description. |
| Auto-insert into other apps | Accessibility | Requested via the Permissions tab. Without it: record/transcribe/Copy still work; transcripts are kept for manual copy. |
| Global shortcut | none extra | Carbon hotkey registration observes nothing; no key content collected. |

- **Input Monitoring is not requested.** **Speech-recognition authorization is
  not requested** (transcription goes to your endpoint).
- **Rebuilding invalidates the Accessibility grant** with the default ad-hoc
  signature (macOS keys grants to the code signature, which changes every
  build). Symptom: transcripts are kept with "Accessibility permission is
  missing" and Insert does nothing. Fix: System Settings → Privacy & Security
  → Accessibility → toggle Open Dictation off and on (or remove it with "−"
  and re-add the new `.app`), then Recheck on the Permissions tab.
- **Stable identity for development**: any code-signing identity in your
  keychain works — an "Apple Development" certificate (free Apple ID), or a
  self-signed one (Keychain Access → Certificate Assistant → Create a
  Certificate… → Identity Type *Self Signed Root*, Certificate Type *Code
  Signing*). List them with `security find-identity -v -p codesigning`. Put
  the identity's name on one line in `scripts/codesign-identity.local`
  (git-ignored) or pass `CODESIGN_IDENTITY="…"`; `package-app.sh` then signs
  with it and grants survive rebuilds. Approve the one-time "codesign wants
  to use the key" prompt with Always Allow. Switching identities (e.g. from
  ad-hoc) requires re-granting once.
- Insertion decisions are logged as reasons only (never transcript text,
  audio, or tokens):
  `log show --last 10m --predicate 'subsystem == "com.example.opendictation"'`.
- The build is **not sandboxed** (no entitlements file): sandboxing would
  block cross-app Accessibility, synthetic paste keystrokes, and the global
  hotkey. Direct distribution only; no App Store submission attempted.

## Shortcut conflicts (incl. Apple's Dictation)

Default: **Option-Shift-Space**. If registration reports a conflict, capture a
different combination in Settings → Shortcut.

To free or move Apple's own Dictation shortcut:
System Settings → Apple Intelligence & Siri (or Keyboard) → Dictation — turn
it off or change its shortcut (commonly "Press Fn Twice"). Our app never
touches Apple's Dictation service; the two coexist once shortcuts differ.

The dedicated microphone / Fn / Globe key cannot be registered by third-party
apps — a conventional modifier shortcut is used instead.

## Troubleshooting

- **"Endpoint URL is invalid"** — enter the full URL including scheme, host,
  and path.
- **Test button** — labeled honestly: it uploads a generated 0.5 s test tone
  through the real adapter (there is no universal health endpoint).
- **Empty transcript / auth errors** — the panel and main window show the
  classified error; audio is kept for explicit Retry only for transient
  failures (network, timeout, 429, 5xx). Nothing retries silently.
- **Insertion refused** — app/window/caret/selection changed, or permission
  missing: the transcript is kept; Copy it or re-focus and Insert from the
  floating panel. The main window's Insert can't work while our window holds
  focus — the UI says so.
- **Mic not working in a raw `swift run` binary** — expected: run the packaged
  `.app`, which carries the usage description and bundle identity.
- **Nothing is logged**: audio, transcript bodies, and tokens never go to logs.

## Project layout

```
Sources/OpenDictationCore/      testable logic: session machine, provider
                                boundary, multipart, WAV, recorder, policies
Sources/OpenDictationApp/       SwiftUI + AppKit: windows, panel, shortcut,
                                AX destination/insertion services
Sources/OpenDictationTestSupport/ shared fakes (XCTest + self-test)
Sources/OpenDictationSelfTest/  dependency-free test runner (CLT hosts)
Tests/OpenDictationCoreTests/   XCTest suite (Xcode hosts)
tools/                          mock server, example config
scripts/                        package-app.sh, run-mock-server.sh
docs/                           ARCHITECTURE, VERIFICATION, FUTURE
```

Further reading: `docs/ARCHITECTURE.md` (session ownership, audio flow,
endpoint contract, destination tracking, insertion limits),
`docs/VERIFICATION.md` (what was checked, what needs an interactive Mac),
`docs/FUTURE.md` (streaming and other extensions).
