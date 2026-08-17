"""Mock of the starOS browser bridge, for testing canvas.sh without Firefox.

Reproduces the response shapes of the real server (mcp-server/server.py) that
matter to the shell helpers:

  GET  /health     unauthenticated, 200, includes browsers_connected
  POST /mcp/call   403 + {"error": "Unauthorized"} when the token is wrong
                   200 + {"success": false, "error": "...timed out..."} when
                        Firefox is not attached  <- the important one
                   200 + {"success": true, ...} on the happy path

The load-bearing detail: a closed browser is NOT silence. The real server
answers 200 with well-formed JSON, so any client that only checks "did I get
JSON back" will treat a dead browser as success.

Usage:  python mock_bridge.py <port> <mode> <token>
        mode = ok | closed | unauthorized
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
MODE = sys.argv[2] if len(sys.argv) > 2 else "closed"
TOKEN = sys.argv[3] if len(sys.argv) > 3 else "test-token"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep test output clean

    def _send(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            # Unauthenticated on the real server, and browsers_connected counts
            # WebSocket clients only - it reads 0 even when the extension is
            # fully attached over HTTP long-poll. Not a usable liveness signal.
            self._send({
                "status": "ok",
                "version": "1.0.0",
                "browsers_connected": 0,
            })
        else:
            self._send({"error": "Not Found"}, 404)

    def do_POST(self):
        if self.headers.get("X-API-Key") != TOKEN:
            self._send({"error": "Unauthorized"}, 403)
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        try:
            req = json.loads(raw)
        except ValueError:
            self._send({"error": "Invalid JSON"}, 200)
            return

        if MODE == "unauthorized":
            self._send({"error": "Unauthorized"}, 403)
            return

        action = req.get("name", "")

        if MODE == "closed":
            self._send({
                "success": False,
                "error": "Command %s timed out waiting for browser response after 30s" % action,
                "action": action,
            })
            return

        if action == "browser_get_tabs":
            self._send({"success": True, "tabs": [
                {"id": 1, "title": "Dashboard", "url": "https://canvas.example.edu/"},
            ]})
        elif action == "browser_get_page_info":
            self._send({"success": True,
                        "url": "https://canvas.example.edu/",
                        "title": "Dashboard"})
        elif action == "browser_navigate":
            self._send({"success": True, "url": req.get("arguments", {}).get("url")})
        elif action == "browser_screenshot":
            self._send({"success": True,
                        "saved_to": req.get("arguments", {}).get("filename"),
                        "echo_args": req.get("arguments", {})})
        else:
            self._send({"error": "Unknown tool: %s" % action})


if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    print("mock bridge on %d mode=%s" % (PORT, MODE), flush=True)
    srv.serve_forever()
