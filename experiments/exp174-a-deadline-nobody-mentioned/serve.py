#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The origin the browser half needs, and the sink its results go into.

    python3 serve.py            # http://localhost:8174

WebAuthn refuses to run outside a secure context, and `file://` has an opaque
origin no relying party id can be derived from. `localhost` is the one plain-http
origin browsers make an exception for, so this is the smallest thing that makes
the page a real relying party rather than a mock: eleven lines of server and a
port.

It also accepts the page's transcript back as a POST and appends it to
`transcript.json`. That is not a convenience. A browser's result would otherwise
have to be read off a screen, and this repository's rule is that a finding lives
in a file somebody else can re-check — see `verify.py`, which reads exactly this
file and does the cryptography again.
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
            self.send_response(400)
            self.end_headers()
            return
        with open(OUT, "ab") as f:
            f.write(body + b"\n")
        self.send_response(204)
        self.end_headers()
        sys.stderr.write("### transcript entry, %d bytes\n" % len(body))
        sys.stderr.flush()

    def log_message(self, fmt, *args):
        sys.stderr.write((fmt % args) + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8174
    print("serving %s on http://localhost:%d" % (PAGE, port))
    print("transcript appends to %s" % OUT)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
