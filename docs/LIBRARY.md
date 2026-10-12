# OpenDictationCore

`OpenDictationCore` is the reusable SwiftPM library in this repository. It
targets macOS 14 and later and has no third-party dependencies. It owns
transcription transport, WAV processing, recording/session coordination,
destination validation, insertion policy, settings, and Keychain access.
The SwiftUI/AppKit application depends on this same library.

Add the package and product to a consuming package:

```swift
dependencies: [
    .package(url: "https://github.com/scshafe/open-dictation.git", from: "0.1.0")
],
targets: [
    .executableTarget(
        name: "YourApp",
        dependencies: [
            .product(name: "OpenDictationCore", package: "open-dictation")
        ]
    )
]
```

Transcribe an existing WAV through an explicitly configured endpoint:

```swift
import Foundation
import OpenDictationCore

func transcribe(wavURL: URL, endpoint: URL, token: String?) async throws -> String {
    let config = ProviderConfig(endpointURL: endpoint, bearerToken: token)
    let result = try await HTTPTranscriptionAdapter().transcribe(
        audioURL: wavURL, config: config
    )
    return result.text
}
```

The adapter sends the supplied audio; callers must provide a compatible WAV
or use `AudioFileConverter` to produce mono 16-bit PCM at 16 kHz. The endpoint
must implement the multipart contract in the root README. Handle
`ProviderError` explicitly; retries remain the caller's decision.

Consumers using recording or insertion must supply application permissions
and implementations of the destination/insertion protocols. Importing the
library does not launch the app, register a shortcut, request microphone
access, or insert text. `SessionCoordinator` runs on the main actor.
Keychain and preference storage identifiers must be chosen deliberately by
consuming apps; do not assume the sample app's defaults are suitable.

Run an independent consuming-package check with:

```sh
python3 scripts/verify-library-consumer.py
# Verify a published revision rather than the current working tree:
python3 scripts/verify-library-consumer.py --revision v0.1.0
```

The check compiles the public product in a temporary package and exercises
response parsing, error classification, configuration, and synthetic WAV
round-tripping. It does not access user audio, credentials, or a real endpoint.
