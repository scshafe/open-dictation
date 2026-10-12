#!/usr/bin/env python3
"""Deterministic mock transcription server for Open Dictation development.

Implements the multipart transcription contract WITHOUT performing speech
recognition: it inspects the multipart request and returns clearly labeled
deterministic text. Stdlib only.

Contract expected:
  POST <any path> with multipart/form-data:
    - file part: audio bytes (filename + audio/* MIME type checked)
    - optional `model` field, optional `language` field
    - optional `Authorization: Bearer ...` header
  Success: {"text": "MOCK TRANSCRIPT ..."}

Usage:
  ./scripts/run-mock-server.sh [--port 8080] [--delay 0.5] [--fail 0]
                               [--empty] [--malformed] [--require-token TOKEN]

Then set the app endpoint URL to, e.g.:
  http://127.0.0.1:8080/v1/audio/transcriptions
(path is ignored by the mock; the app sends exactly what you configure.)
"""

import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class State:
    delay = 0.0
    fail_status = 0
    empty = False
    malformed = False
    require_token = None
    request_count = 0


def parse_multipart(body: bytes, boundary: bytes):
    """Minimal multipart parser. Returns (fields, files)."""
    fields, files = {}, []
    for chunk in body.split(b"--" + boundary):
        if not chunk or chunk in (b"--", b"--\r\n"):
            continue
        head, sep, data = chunk.partition(b"\r\n\r\n")
        if not sep:
            continue
        data = data[: -len(b"\r\n")] if data.endswith(b"\r\n") else data
        headers = head.decode("latin1")
        name = re.search(r'name="([^"]*)"', headers)
        filename = re.search(r'filename="([^"]*)"', headers)
        ctype = re.search(r"Content-Type:\s*([^\r\n]+)", headers)
        if not name:
            continue
        if filename:
            files.append(
                {
                    "name": name.group(1),
                    "filename": filename.group(1),
                    "content_type": ctype.group(1).strip() if ctype else None,
                    "bytes": len(data),
                    "riff": data[:4] == b"RIFF",
                }
            )
        else:
            fields[name.group(1)] = data.decode("utf-8", "replace")
    return fields, files


class Handler(BaseHTTPRequestHandler):
    server_version = "MockTranscription/1.0"

    def log_message(self, *args):
        pass  # keep output clean; we print our own summary lines

    def do_GET(self):
        info = {
            "server": "mock-transcription",
            "note": "Mock only: returns deterministic text, performs no recognition.",
            "usage": "POST multipart/form-data with a 'file' part; optional 'model'/'language'.",
        }
        payload = json.dumps(info).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        State.request_count += 1
        if State.delay:
            time.sleep(State.delay)

        if State.require_token:
            auth = self.headers.get("Authorization", "")
            if auth != f"Bearer {State.require_token}":
                return self._send(401, {"error": "invalid token (mock auth)"})

        if State.fail_status:
            return self._send(State.fail_status, {"error": f"mock failure {State.fail_status}"})

        ctype = self.headers.get("Content-Type", "")
        m = re.search(r"boundary=([^\s;]+)", ctype)
        if "multipart/form-data" not in ctype or not m:
            return self._send(400, {"error": "expected multipart/form-data with boundary"})
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        fields, files = parse_multipart(body, m.group(1).encode())

        audio = next((f for f in files if f["name"] == "file"), None)
        if audio is None:
            return self._send(400, {"error": "missing 'file' part"})
        if audio["content_type"] and not audio["content_type"].startswith("audio/"):
            print(f"[mock] WARNING: file MIME type is {audio['content_type']!r}, expected audio/*")

        print(
            f"[mock] #{State.request_count} path={self.path} file={audio['filename']} "
            f"mime={audio['content_type']} bytes={audio['bytes']} riff={audio['riff']} "
            f"model={fields.get('model')} language={fields.get('language')}"
        )

        if State.malformed:
            return self._send_raw(200, b"not json", "application/json")
        if State.empty:
            return self._send(200, {"text": "   "})
        text = (
            f"MOCK TRANSCRIPT #{State.request_count}: received {audio['filename']} "
            f"({audio['bytes']} bytes, model={fields.get('model', '-')}, "
            f"language={fields.get('language', '-')}). This is deterministic test output, "
            f"not speech recognition."
        )
        return self._send(200, {"text": text})

    def _send(self, status, obj):
        payload = json.dumps(obj).encode()
        self._send_raw(status, payload, "application/json")

    def _send_raw(self, status, payload, ctype):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    parser = argparse.ArgumentParser(description="Mock transcription server (no real recognition).")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--delay", type=float, default=0.0, help="seconds to delay each response")
    parser.add_argument("--fail", type=int, default=0, help="always respond with this HTTP status")
    parser.add_argument("--empty", action="store_true", help="return empty transcript text")
    parser.add_argument("--malformed", action="store_true", help="return invalid JSON")
    parser.add_argument("--require-token", default=None, help="require this bearer token")
    args = parser.parse_args()

    State.delay = args.delay
    State.fail_status = args.fail
    State.empty = args.empty
    State.malformed = args.malformed
    State.require_token = args.require_token

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[mock] listening on http://127.0.0.1:{args.port} (any path accepts the contract)")
    print("[mock] point the app endpoint URL here, e.g. http://127.0.0.1:8080/v1/audio/transcriptions")
    server.serve_forever()


if __name__ == "__main__":
    main()
