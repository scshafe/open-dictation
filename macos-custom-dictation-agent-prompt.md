# Build a native macOS custom dictation application

You are acting as the lead engineer for a new native macOS application. Build the project from scratch in the current workspace. Deliver working code, a reproducible build, focused tests, and practical documentation. Proceed through implementation and verification; do not stop after proposing an architecture or generating a UI mockup.

## 1. Product goal and boundaries

I want my own system-wide dictation app. While typing in another application, I should be able to press a shortcut, speak, see my own recording UI, and have the resulting transcript inserted at my intended cursor position. The audio must go to a transcription endpoint that I configure, rather than requiring Apple's recognition service or a particular commercial provider.

The endpoint might be on the same Mac, on another machine on my network, or on a remote server. A usable app must not require an account, subscription, telemetry, or an internet connection beyond what the configured endpoint itself needs.

The app also needs a regular window for reviewing/editing a transcript and configuring dictation. Its floating recording panel must be able to appear while I continue working in another app.

Treat this as an independent dictation application with its own shortcut, microphone capture, networking, and UI. Do not base the project on redirecting Apple's internal Dictation service, replacing protected system components, or using private APIs. Explain how a user can manually disable or reassign Apple's Dictation shortcut if it conflicts.

Build a useful first release, with a clean path to later streaming transcription. Reliability, faithful transcription, and correct text placement matter more than animated polish or a large feature set.

## 2. Working assumptions and execution

Use these defaults unless the existing workspace or installed toolchain provides a concrete reason to adjust them:

- Working name: **Open Dictation**. This is a placeholder, not a branding or trademark determination.
- Native Swift, SwiftUI for ordinary views, and AppKit for application/window integration.
- Target macOS 14 or later initially, with Apple Silicon as the primary development target. Avoid unnecessary architecture-specific code.
- Use a stable installed Xcode/Swift toolchain. Check API availability against the actual deployment target.
- A menu-bar application that can open normal windows. Closing a window must not silently terminate background shortcut functionality.
- Local development and direct distribution first. Do not make App Store submission, a paid signing identity, notarization, or a cloud deployment a prerequisite for development.
- Keep dependencies minimal. Use a small maintained dependency only when it materially reduces platform integration risk; explain the choice and pin its version.

First inspect the workspace and any applicable AGENTS.md instructions, then check the host OS and development tools. Preserve existing work. If this is an empty workspace, scaffold it. If a project already exists, integrate with its conventions.

Make routine implementation decisions yourself and document meaningful assumptions. Ask only when missing information genuinely blocks progress. Missing API credentials do not block development: supply a local mock server and test fixtures. Do not require the user to select an ASR model before the client works.

If the current host cannot run Xcode or macOS UI tests, still implement the project and all feasible checks. Explicitly distinguish static checks from successful macOS compilation and interactive verification. Never claim to have tested a Mac UI on a non-Mac host.

## 3. Required first-release interaction

Implement this complete flow:

1. Launch the app and configure the full transcription URL and any required model/authentication settings.
2. Put the cursor in a text field in another app, such as TextEdit.
3. Press a configurable global keyboard shortcut. A proposed default is Option-Shift-Space, subject to conflict checking.
4. Capture the intended destination before showing UI: application identity, focused editable element, and selection information where available.
5. Show a compact floating panel and begin recording after microphone access is available.
6. Display an actual microphone level, elapsed duration, and a clear recording state.
7. Press the shortcut again, or click Stop, to finish recording and begin transcription.
8. Display a transcribing state, followed by the returned text.
9. If automatic insertion is enabled and the original destination is still valid, insert the final transcript once. Otherwise retain the result and explain how to copy it or explicitly insert it into a selected destination.

Also support recording from the app's normal window, where the transcript remains in that window for review. Do not infer an external insertion target when recording begins inside the app.

Provide cancellation during recording and transcription. A canceled or superseded session must never insert text later when a delayed callback arrives. Keep stopping and canceling semantically distinct: Stop requests a transcript; Cancel discards the pending operation.

The normal default is manual stop. Do not add a short silence timeout that cuts off a user thinking between sentences. Any necessary duration or file-size limit must be visible and must not silently truncate a recording.

## 4. UI and focus behavior

### Floating panel

Use an AppKit NSPanel hosting SwiftUI content, with appropriate nonactivating behavior. Merely showing or updating the recording panel must not activate the app or take keyboard focus away from the destination. Verify this behavior; choosing a window style alone is not sufficient proof.

Include recording/transcribing/result/error states, a measured audio level, elapsed time, Stop, and Cancel. Keep it compact and readable in light and dark mode. Put it on the display associated with the active work where feasible and clamp its position to the visible screen area.

Give controls accessibility labels, respect reduced motion, and avoid tiny text or color-only state indicators. Handle ordinary Spaces and document any full-screen behavior that still needs device testing.

Opening the normal transcript window for editing is an intentional focus change. Preserve the pending result, but invalidate automatic insertion until the destination is explicitly re-established. Do not bring an unrelated application to the foreground to force a paste.

### Main window and settings

Provide a simple transcript editor with Record, Stop, Cancel, Copy, and Clear. Show endpoint connection/error status without exposing credentials. Offer settings for endpoint configuration, shortcut, insertion mode, and microphone behavior.

Show the current input device. The system default microphone is sufficient for the first release; explicit device selection is an extension if it does not delay the core flow. Handle disappearance or changes of the input device gracefully.

Provide a permission status view with clear recovery instructions. A user who declines cross-app permissions must still be able to record, transcribe, and manually copy text.

Persistent transcript history is not required for the first release. Keep uncommitted results available during the session, and document what happens when the app quits. Do not silently enable recording archives.

## 5. Audio capture and lifecycle

Use public macOS audio APIs, such as AVAudioEngine. Request microphone access only in an appropriate user-initiated flow and supply an accurate usage description.

Keep network operations, blocking file I/O, and expensive format conversion off the real-time audio callback. Use a bounded buffering/processing design and report overload rather than growing memory indefinitely or silently losing samples.

Capture in an appropriate device-native format and convert correctly for the endpoint adapter. For the default adapter, a mono 16-bit PCM WAV file at a documented supported rate, such as 16 kHz, is a reasonable starting point. Resample the audio; never just relabel the sample rate. Verify the WAV header, duration, channel count, and samples in tests.

Stop and release microphone resources on completion, cancellation, permission loss, sleep/interruption, and app termination as appropriate. Avoid duplicate audio taps when starting another session. Handle startup and conversion failures without leaving the UI stuck in Recording.

Temporary audio may be retained privately while a failed request is available for explicit Retry. Remove it after successful transcription, cancellation, or dismissal of the retryable session. Clean up abandoned temporary recordings on a subsequent launch. Do not retain audio or write transcripts to logs by default.

## 6. Transcription endpoint and provider boundary

Create a small provider abstraction so transport details are separate from recording and UI. Implement one real batch HTTP adapter and a deterministic fake provider. Do not build a general plugin loader or a backend marketplace.

For the real adapter, implement and document this explicit **multipart transcription contract**:

- User-configured full request URL, including the path. Do not guess or append paths behind the user's back.
- HTTP POST with multipart/form-data and a correctly generated boundary.
- A `file` part containing the audio, with an appropriate filename and MIME type.
- A configurable `model` string, sent only when populated.
- An optional `language` field, sent only when populated.
- Optional bearer-token authentication. Omit the Authorization header when no token is configured.
- A successful JSON response containing a string `text` field, for example:

```json
{"text": "This is the final transcript."}
```

This is an OpenAI-style subset, not a promise that every server with an OpenAI-compatible label supports every field, audio format, or behavior. Keep provider-specific additions out of the recording code. No OpenAI SDK or OpenAI account is required.

Use URLSession or an equally justified native mechanism. Include cancellation, reasonable configurable request/resource timeouts, bounded response handling, and useful treatment of DNS/connectivity errors, authentication failures, unsupported uploads, rate limits, server failures, malformed JSON, and empty transcripts. Do not insert server error bodies as text.

Retain a failed session for explicit retry when appropriate. Avoid unbounded or hidden automatic retries that might duplicate paid requests. Handle redirects deliberately so credentials and audio are not silently forwarded to a different origin.

Support HTTPS with ordinary certificate validation. Support explicitly configured local development HTTP where macOS networking policy permits it; make any required transport exceptions as narrow as practical and document them. Do not disable TLS verification or silently fall back to a remote service. Distinguish transport configuration problems from server errors.

Store credentials in Keychain and ordinary preferences in a suitable local settings store. Never place tokens in source control, ordinary preferences, analytics, or diagnostic logs.

Provide a local mock HTTP server that implements the contract, inspects the multipart request, returns clearly labeled deterministic text, and can simulate delay and failure. It must not pretend to perform speech recognition. Keep its dependencies minimal and its launch command documented.

Do not invent a universal health endpoint for a Test Connection button. A connection check must have a documented meaning; if it uploads a bundled sample clip, label that action clearly.

## 7. Text insertion: correctness before convenience

Create a dedicated destination-tracking and insertion component. This is a central reliability concern, not incidental UI glue.

Support two user-visible insertion modes:

- **Insert automatically when safe:** after transcription, attempt one insertion only if the intended destination remains valid.
- **Review/copy:** retain the transcript and let the user decide where it goes.

Before automatic insertion, revalidate the original application, focused element, and selection/context where supported. Treat switching windows, moving the caret, changing selected text, closing the target, or uncertainty about identity as reasons to retain the transcript instead of guessing. A focus change away and back should not automatically imply the original insertion position survived.

Do not collect full documents or broad screen contents to perform this check. Read only the minimal relevant accessibility information. There is an unavoidable race between validation and cross-app input; minimize it and document the limit rather than claiming atomic insertion.

Prefer a targeted Accessibility operation where the field supports it. Check which attributes are writable. Do not blindly replace the entire field value as a substitute for inserting at the selection. Respect selected text replacement as normal typing would.

Use clipboard-and-paste as a compatibility fallback when direct insertion is not supported and the destination remains valid. If you temporarily change the clipboard, preserve its contents as faithfully as feasible and restore them only when it is safe. Account for pasteboard change counts, other apps changing the clipboard, multiple representations, and asynchronous paste consumption. Do not claim a fixed sleep makes restoration universally reliable. If restoration cannot be made reliable for a path, document the behavior and provide a straightforward Copy action.

Distinguish unsupported insertion, confirmed failure, successful insertion, and uncertain completion. Do not follow an ambiguous direct-insertion result with a paste that might duplicate the transcript. Never repeatedly paste because a success signal was unavailable.

If Accessibility access is missing, the target cannot be identified, or the field is protected or unsupported, keep the result available and explain the fallback. Do not try to bypass secure input restrictions. Pressing Copy should deliberately place the transcript on the clipboard without restoring the old clipboard immediately afterward.

Only commit final transcription text in the first release. Partial hypotheses may later be displayed in the panel, but should not be repeatedly written into another app while they are still changing. Preserve the provider's text; do not add LLM rewriting or stylistic cleanup by default.

## 8. Shortcuts and permission handling

Implement a configurable global shortcut using an appropriate supported approach verified against the current SDK. Handle conflicts and registration failures clearly, unregister old bindings when changing settings, and ignore key-repeat as repeated start/stop commands.

Do not promise the dedicated microphone key, Fn/Globe, or every system-reserved combination can be reassigned. A conventional modifier shortcut is enough for the first release. Avoid collecting general keystroke content.

Microphone access, Accessibility trust, and Input Monitoring have different purposes. Request only permissions needed by the chosen implementation, and document which feature requires each. Input Monitoring should not be requested merely because the app has a shortcut. Do not request Apple's speech-recognition authorization unless an implemented optional Apple recognition backend actually needs it.

Explain whether the chosen development build is sandboxed and why. Resolve the actual entitlements and platform constraints; do not paste in a speculative entitlement list. Never suggest disabling System Integrity Protection or changing protected OS files.

Use explicit permission refresh/recheck behavior when returning from System Settings. Account for the possibility that rebuilding or changing signing identity affects the user's trust grants. Keep ordinary development usable without paid distribution credentials.

## 9. Architecture and asynchronous state

Use clear, testable boundaries without making the project a framework. Suggested responsibilities, with names left to your judgment:

- App lifecycle and menu-bar integration.
- A session coordinator/state machine.
- Microphone capture and audio conversion.
- Transcription provider and HTTP transport.
- Destination tracking and text insertion.
- Global shortcut management.
- Floating panel and main/settings windows.
- Preferences, Keychain access, and permission status.

Model states such as idle, preparing, recording, transcribing, result ready, inserting, completed, canceled, and failed. Define allowed transitions and own cleanup in one place. Distinguish recoverable network failure from a discarded recording.

Assign every session an identity. Late audio callbacks, retries, endpoint responses, and UI actions must be checked against the active session. Cancellation and cleanup should be idempotent. A new recording must not receive an old transcript, old error, or insertion callback.

Snapshot provider configuration for a session so editing Settings does not unexpectedly change a request already in progress. Keep UI mutation on the main actor and asynchronous audio/network work in appropriate execution contexts. Prefer explicit ownership and dependency injection over mutable global singletons.

Do not erase an uncommitted transcript just because another recording starts. Either retain it in the main window or require an explicit discard action. Keep the behavior simple and documented.

## 10. Implementation order

Work in small, buildable increments. Maintain a short plan and update it as real constraints become clear.

1. **Project foundation:** runnable macOS app target, reproducible project setup, menu bar, main window, settings, and session model. Use a fake provider to exercise UI states immediately.
2. **Audio-to-endpoint vertical slice:** record real microphone audio, finalize/convert it, call the configurable batch endpoint, display the returned transcript, and support Copy. Exercise the real HTTP transport against the mock server.
3. **System-wide workflow:** global shortcut, destination capture, floating panel without focus theft, and conservative insertion with fallback handling.
4. **Reliability and usability:** permissions, cancellation races, errors/retry, device changes, clipboard behavior, transcript editing, keyboard navigation, and concise status messages.
5. **Verification and handoff:** focused tests, macOS build/run checks where available, manual compatibility results, and setup documentation.

Do not stop after step 1 or a mock-only demo. The required endpoint client and system-wide workflow must be implemented. If blocked by unavailable host capabilities, complete the code and identify the exact remaining Mac verification work.

## 11. Focused automated tests

Prioritize meaningful tests for the behavior most likely to lose text, duplicate text, or leak state between sessions:

- Session transitions, double-stop, cancellation, and stale responses arriving after a new recording.
- Multipart encoding, optional fields/authentication, successful JSON decoding, malformed/empty responses, timeouts, and error classification.
- Audio conversion with a deterministic fixture, including sample rate, duration, channel count, and a valid WAV payload.
- Destination changes and refusal to insert into a changed or unknown field.
- Exactly-once insertion attempts, uncertain completion, and no duplicate fallback paste.
- Clipboard restoration decisions when another process changes the pasteboard.
- Resource cleanup after cancellation and retryable versus terminal failure.

Use fake providers and isolated adapters for deterministic tests. Real Accessibility and focus behavior must also be checked interactively; unit tests cannot establish universal compatibility with third-party apps. Avoid live paid API calls in automated tests.

## 12. Acceptance checks

The implementation is ready for handoff when the following are implemented and the available checks have actually been performed:

- A clean checkout opens/builds with documented commands and produces a launchable .app on the supported Mac toolchain.
- The main-window record-to-transcript-to-copy path works through the actual HTTP adapter.
- The mock server validates the upload contract, and its outputs are clearly identified as test results.
- A configured real endpoint can be used without source edits. If no real endpoint is available, report that end-to-end recognition remains unverified.
- The global shortcut starts and stops one recording while TextEdit remains the typing destination.
- The panel appears and updates without taking focus; its Stop and Cancel controls behave as documented.
- A final transcript can be inserted into an unchanged supported TextEdit selection exactly once.
- Changing app, window, caret position, or selected text during recording/transcription prevents stale automatic insertion.
- Unsupported fields and missing cross-app permissions leave the transcript available for manual copy.
- Network failure, cancellation, and delayed callbacks do not lose a recoverable result, leave the microphone running, or trigger late insertion.
- Repeating several recording sessions does not create duplicate taps, shortcuts, panels, or stale state.
- Settings persist, credentials are in Keychain, and normal logs contain no recorded audio, transcript bodies, or secrets.

Where installed, also manually check a Safari textarea and one Electron-based editor or messaging app. Keep a small compatibility table with app, tested operation, outcome, and known limitation. Include Spaces/full-screen and input-device-change cases if the host permits. Mark unperformed checks as untested, never passed by assumption.

## 13. Deliverables

Produce:

- Complete source code and a reproducible macOS project, with a shared build scheme. Prefer a checked-in Xcode project or a documented deterministic generator with pinned dependencies; no unexplained local-only setup.
- An automated test target and the focused tests above.
- A local mock transcription server, deterministic fixtures, and example nonsecret configuration.
- A README covering prerequisites, exact build/run/test commands, endpoint setup, permission flows, shortcut conflicts, troubleshooting, and development signing.
- A concise architecture note describing session ownership, audio flow, endpoint contract, destination tracking, focus behavior, and insertion limitations.
- A manual verification checklist with actual results separated from pending checks.
- A short future-work list, limited to useful extensions such as streaming providers, explicit microphone selection, push-to-talk, opt-in history, and deeper input-method integration.

Keep generated build products, recordings, credentials, and machine-specific files out of version control. Do not publish, deploy, or purchase services as part of this task.

## 14. Scope control and future streaming

The required first release is batch transcription after stopping, with genuine recording feedback and a fully custom UI. Streaming is a later enhancement unless an actual endpoint protocol is already supplied. Do not display fake incremental recognition or imply an HTTP batch endpoint supports live results.

Leave the provider boundary easy to extend for partial/final events, but do not implement an imaginary WebSocket protocol, extensive realtime infrastructure, ASR model training, a bundled model manager, an LLM rewrite pipeline, or a custom InputMethodKit input source in the first release.

If streaming is implemented later, verify the chosen server's protocol, handle partial revisions and finalization explicitly, and display partial text in the panel while preserving conservative final insertion.

## 15. Reference points and final handoff

Check current Apple documentation and the installed SDK before relying on permission behavior, window activation, audio APIs, or shortcut registration. Useful starting points:

- [Apple Dictation settings and shortcuts](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac)
- [AVAudioEngine](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Nonactivating panel style](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [Accessibility interaction model](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html) — archived conceptual reference; verify exact APIs and permissions against current documentation.
- [InputMethodKit](https://developer.apple.com/documentation/inputmethodkit) — background for a possible later integration, not the first-release architecture.

At the end, report what works, exactly how to launch it, which builds/tests you ran, what requires user permission or real-Mac verification, and any concrete limitations. Mention tradeoffs that affect behavior, especially text insertion and clipboard handling. Do not substitute a proposed plan for the implementation.

Start now by inspecting the environment, making a short implementation plan, and building the first runnable vertical slice. Continue through the required first release.
