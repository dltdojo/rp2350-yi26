#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Serve exp176's registration page and capture what a browser gets back.

    python3 serve.py            # http://localhost:8176

WebAuthn will not run on file://, and localhost is the one plain-http origin a
browser makes an exception for. The page registers a credential with whatever
authenticator you pick — the board or a commercial key — asks for attestation
'direct', and posts the attestationObject here. attest.py reads it. No PIN typed
at a shell: the browser asks the authenticator the way a website does, and a
person only touches (and enters a PIN in the browser's own dialog if the key
insists on one).
"""
import http.server
import json
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(ROOT, "page")
OUT = os.path.join(ROOT, "transcript.json")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=PAGE, **kw)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        try:
            json.loads(body)
        except ValueError:
            self.send_response(400); self.end_headers(); return
        with open(OUT, "ab") as f:
            f.write(body + b"\n")
        self.send_response(204); self.end_headers()
        sys.stderr.write("### captured %d bytes\n" % len(body)); sys.stderr.flush()

    def log_message(self, fmt, *a):
        sys.stderr.write((fmt % a) + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8176
    print("serving %s on http://localhost:%d" % (PAGE, port))
    print("attestations append to %s" % OUT)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
