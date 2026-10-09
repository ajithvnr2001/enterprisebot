"""Minimal HTTP service for DevOps take-home (Part 1).

Endpoints:
  GET /        -> {"app": APP_NAME, "version": VERSION, "pod": hostname}
  GET /healthz -> 200 {"status": "ok"} when healthy
Env:
  APP_NAME (default: demo)
  VERSION  (default: 0.1.0)
  PORT     (default: 8080)
Uses only the Python standard library (no dependencies).
"""
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

APP_NAME = os.environ.get("APP_NAME", "demo")
VERSION = os.environ.get("VERSION", "0.1.0")
PORT = int(os.environ.get("PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self._send_json(200, {
                "app": APP_NAME,
                "version": VERSION,
                "pod": socket.gethostname(),
            })
        elif self.path == "/healthz":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # Keep logs quiet but useful: METHOD PATH -> CODE
        print(f"{self.command} {self.path} -> {args[1] if len(args) > 1 else '?'}", flush=True)


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"demo-service starting: app={APP_NAME} version={VERSION} listening on :{PORT}", flush=True)
    server.serve_forever()
