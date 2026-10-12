# Open Dictation

Native macOS app and reusable `OpenDictationCore` SwiftPM product. Read
`docs/ARCHITECTURE.md` for ownership and `docs/LIBRARY.md` for consumption.

- Keep shared dictation capabilities in Core; the app supplies platform UI
  and destination/insertion adapters. Extend existing interfaces before
  adding another implementation of the same capability.
- Do not log audio, transcript bodies, tokens, signing identities, or private
  endpoint details. Keep credentials in Keychain and local configuration out
  of Git. Never inspect user recordings for automated verification.
- Run `swift run OpenDictationSelfTest` and
  `python3 scripts/verify-library-consumer.py` after relevant code changes.
  With full Xcode, also run `swift test`.
- Package with `CODESIGN_IDENTITY=- ./scripts/package-app.sh release` for
  reproducible ad-hoc verification without accessing a personal signing key.
- Use synthetic audio and the local mock server for network tests. Real
  microphone, focus, Accessibility insertion, and live endpoint checks require
  separate interactive verification; do not mark them passed by inference.
