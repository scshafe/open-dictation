# Future work (explicitly out of v1 scope)

- **Streaming providers**: new protocol with partial/final events beside the
  batch `TranscriptionProvider`; verify the actual server protocol first.
  Show partials in the panel only; keep conservative final-only insertion.
- **Explicit microphone selection**: enumerate input devices; v1 uses the
  system default and shows its name.
- **Push-to-talk**: hold-shortcut mode in `ShortcutManager` (press/release
  events) alongside toggle.
- **Opt-in transcript history**: persisted store with explicit retention
  controls; v1 keeps results in memory for the session only.
- **Deeper input-method integration**: InputMethodKit background study for a
  possible later input source; not the v1 architecture.
- **Broader insertion backends**: per-app quirks table driven by the manual
  compat results; never silent multi-paste.
- **Packaging**: Developer-ID signing + notarization for wider distribution;
  no code changes expected (bundle id stays stable for trust grants).
