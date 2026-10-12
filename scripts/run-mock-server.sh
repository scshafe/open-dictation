#!/bin/sh
# Launch the deterministic mock transcription server (stdlib only, no deps).
# Usage: ./scripts/run-mock-server.sh [--port 8080] [--delay 0.5] [--fail 0] ...
# See tools/mock_transcription_server.py --help for all flags.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -u "$ROOT/tools/mock_transcription_server.py" "$@"
