"""Minimal stand-in for the Firecrawl v2 API, used for offline end-to-end runs."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / "tests" / "fixtures"
KEY = "fc-mock-key"
TRIGGERS = {
    "trigger-401": (401, {"success": False, "error": "Unauthorized: Invalid token"}),
    "trigger-402": (402, {"success": False, "error": "Insufficient credits to perform this request."}),
    "trigger-429": (429, {"success": False, "error": "Rate limit exceeded."}),
}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        sys.stderr.write(f"{self.path} {json.dumps(body)}\n")
        if self.headers.get("Authorization") != f"Bearer {KEY}":
            return self.send(401, {"success": False, "error": "Unauthorized: Invalid token"})
        if body.get("origin") != "codecompanion":
            return self.send(400, {"success": False, "error": "missing origin"})
        trigger = body.get("query") or body.get("url", "").rsplit("/", 1)[-1]
        if trigger == "trigger-timeout":
            time.sleep(10)
        if trigger in TRIGGERS:
            return self.send(*TRIGGERS[trigger])
        name = {"/v2/search": "search.json", "/v2/scrape": "scrape.json"}.get(self.path)
        if not name:
            return self.send(404, {"success": False, "error": "not found"})
        self.send(200, json.loads((FIXTURES / name).read_text()))

    def send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 3999), Handler).serve_forever()
