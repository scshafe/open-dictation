# Verification

The historical results below describe the original development session.
Private server details have been replaced with placeholders. Interactive
checks remain pending unless explicitly recorded otherwise.

Host for automated checks: macOS 26.6.1 arm64, Swift 6.3.1, CLT-only (no
Xcode — XCTest module unavailable, so the dependency-free runner below is
the executed suite; the XCTest sources are parse-checked and mirror it).

## Publication checks (2026-10-12)

- Dependency-free runner: **161 checks, 0 failures** on the publication host.
- Real HTTP adapter against a temporary loopback mock: **2 checks, 0 failures**.
- Independent SwiftPM consumer: public library compilation, response/error
  parsing, configuration, and synthetic WAV round-trip passed.
- App release packaging and ad-hoc signature verification passed.
- XCTest runs in macOS CI with full Xcode; the local host uses Command Line
  Tools. Interactive microphone, focus, shortcut, and insertion checks below
  remain unverified in this publication pass.

## Historical development checks (2026-09-10)

- `swift build` — clean (warnings only: Sendable/`await` style notes).
- `swift run OpenDictationSelfTest` — **157 checks, 0 failures**: session
  transitions, double-stop, cancel-during-recording/transcription, stale
  response isolation, exactly-once insertion, fallback-only-after-unsupported,
  no-paste-after-uncertain, concurrent-insert refusal, retryable-vs-terminal
  failure, audio cleanup on success/cancel/discard, retention of uncommitted
  transcripts, editor-open invalidation, recorder-failure and invalid-endpoint
  handling, multipart encoding + conditional fields/auth, response parsing +
  status classification, WAV validity, real 44.1k→16k resample, buffer
  conversion exactness, destination refusal cases, clipboard policy, adapter
  success/error/timeout/size-guard via stubbed transport, redirect-guard
  same-origin-follow / cross-origin-refuse, refused-redirect 3xx →
  `redirectBlocked`, origin comparison including the effective port,
  capture-file processing-format pinning with lossless >4096-frame writes for
  mono and stereo, direct-write confirmation signals (echoed selection /
  string-for-range / caret-after-text), microphone prompt granted and denied
  paths, visible duration limit, input-device change, system sleep, and retry
  from a retained session.
- Empirical AVAudioFile probe (this host): the two-argument
  `AVAudioFile(forWriting:settings:)` yields a deinterleaved processing format
  for 2-channel input, and every interleaved write then fails with -50 (mono
  was unaffected). Pinning the format with the four-argument initializer
  writes 33,472 frames losslessly for both channel counts. Fixed in
  `AudioRecorder.makeCaptureFile`; regression-tested in both runners.
- Keychain probe (this host): SecItemAdd / SecItemUpdate / SecItemCopyMatching /
  SecItemDelete with the app's exact query all return errSecSuccess.
- App Transport Security probe (this host): a bundle carrying the project
  Info.plist reaches plain `http://` on loopback; a LAN address was not
  blocked by ATS (no -1022), though the macOS Application Firewall / Local
  Network privacy can still stall LAN traffic until the user allows it.
- `swift run OpenDictationSelfTest --live-mock http://127.0.0.1:18096`
  against `tools/mock_transcription_server.py` — real adapter → real server,
  contract confirmed server-side
  (`file=recording.wav mime=audio/wav riff=True model=live-probe`).
- Mock server curl checks: multipart inspection, missing-file 400, token
  401/200, `--fail 500`, deterministic `MOCK TRANSCRIPT` labeling.
- `./scripts/package-app.sh` (debug) — produces signed `.app`; launch stays
  resident with no crash; quits cleanly on Apple event. (Process-level check;
  windowing not assertable without assistive access in this environment.)

- Real endpoint, unauthenticated (2026-09-10): Open WebUI's embedded STT at
  `https://<host>.<tailnet>.ts.net/api/v1/audio/transcriptions`
  over Tailscale — MagicDNS resolves, Let's Encrypt certificate validates with
  ordinary system TLS, and both `curl` and the app's own adapter
  (`swift run OpenDictationSelfTest --live-endpoint app --clip …`) receive
  `401 {"detail":"Not authenticated"}`, classified as the auth error. App
  preferences were set to that URL with `language=en` and 300 s / 900 s
  timeouts and decode correctly.
- Real endpoint, authenticated (2026-09-10, same server): with an Open WebUI
  API key saved as the bearer token in the app (Keychain), `swift run
  OpenDictationSelfTest --live-endpoint app --clip clip.wav` sent a 4.0 s
  `say`-generated clip ("This is the Open Dictation test clip. One, two,
  three.") and received `"This is the open dictation test clip, 1, 2, 3."`
  in 1.4 s — **authentication and end-to-end recognition confirmed** through
  the app's real adapter. The interactive in-app flows (item 10 below and
  items 1–9) remain to be exercised by hand.

## Requires an interactive Mac (procedures; all UNTESTED, not assumed)

1. **Main-window record→transcribe→copy**: launch `.app`, grant mic, point at
   mock, Record 3 s, Stop → `MOCK TRANSCRIPT` appears; Copy works.
2. **Shortcut start/stop in TextEdit**: put caret in TextEdit, press
   ⌥⇧Space → panel appears, TextEdit stays frontmost (caret still blinks;
   typing still lands in TextEdit); press again → transcribing → result.
3. **No focus theft**: panel show AND elapsed/level updates never activate the
   app; Stop/Cancel clickable without focus change. (Controller logs + records
   a focus check per presentation; confirm frontmost bundle unchanged.)
4. **Auto-insert once**: unchanged TextEdit selection → text inserted exactly
   once at caret; selected text replaced as typing would.
5. **Stale refusal**: during recording/transcription, switch app / window /
   move caret / change selection → no insertion; transcript kept with reason.
6. **Fallbacks**: field without AX support → single paste, clipboard restored;
   missing Accessibility → kept + Copy guidance; secure field → refused.
7. **Errors**: kill mock mid-request → classified error, audio kept, explicit
   Retry succeeds after restart; Cancel mid-transcription → no late insert.
8. **Devices**: unplug/change input mid-recording → loud stop, no hang.
9. **Compat table**: Safari textarea; one Electron app (e.g. VS Code/Slack);
   Spaces switching; full-screen Space; record verdicts per app/operation.
10. **Real endpoint, in-app**: CLI recognition is confirmed (see Performed).
    Still untested by hand: the Settings "Send 0.5 s test tone" button against
    this server (expect the "empty transcript … transport and authentication
    work" success line) and a spoken dictation from the Dictate tab and from
    TextEdit via the shortcut.

Record results (pass/fail + build date) in a copy of this file or the repo
issue tracker; do not mark items passed by assumption.
