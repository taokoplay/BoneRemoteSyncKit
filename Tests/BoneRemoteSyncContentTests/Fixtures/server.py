#!/usr/bin/env python3
"""Loopback-only content transport fixture; fake credentials, no external access."""
import json
import pathlib
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

root = pathlib.Path(sys.argv[1])
lock = threading.Lock()
payload = b"PK\x03\x04content-fixture" * 8192


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = urlsplit(self.path).path
        with lock:
            with (root / "requests.jsonl").open("a") as log:
                log.write(json.dumps({"path": path, "time": time.monotonic(),
                                      "authorization": self.headers.get("Authorization"),
                                      "key": self.headers.get("X-API-Key"),
                                      "cookie": self.headers.get("Cookie")}) + "\n")
        if path == "/mount/api/slow":
            time.sleep(2)
        if path == "/mount/api/redirect":
            return self.reply(b"", status=302, extra={"Location": "/elsewhere?secret=do-not-follow"})
        if path == "/mount/api/rate":
            return self.reply(b'{"secret":"do-not-expose"}', status=429, extra={"Retry-After": "7"})
        if path == "/mount/api/auth":
            return self.reply(b'{"secret":"do-not-expose"}', status=401)
        if path == "/mount/api/large":
            return self.reply(b" " * 4096)
        if path == "/mount/api/chunked-large":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"1000\r\n" + b" " * 4096 + b"\r\n0\r\n\r\n")
            return
        if path == "/mount/api/image":
            return self.reply(b"\x89PNG\r\n\x1a\nfixture", mime="image/png")
        if path == "/mount/api/html":
            return self.reply(b"<html>login-secret</html>", mime="text/html")
        if path == "/mount/api/empty":
            return self.reply(b"", mime="", status=204)
        if path == "/mount/api/file":
            return self.reply(payload, mime="application/octet-stream")
        if path == "/mount/api/fake-file":
            return self.reply(b"<html>login-secret</html>", mime="application/octet-stream")
        if path == "/mount/api/short-file":
            return self.reply(payload[:16], mime="application/octet-stream", length=len(payload))
        if path == "/mount/api/partial":
            return self.reply(payload[:16], mime="application/octet-stream", status=206)
        if path == "/mount/api/slow-file":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                for index in range(0, len(payload), 1024):
                    self.wfile.write(payload[index:index + 1024])
                    self.wfile.flush()
                    time.sleep(0.02)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        return self.reply(b'{"ok":true}', extra={"Set-Cookie": "must-not-return=1"})

    def reply(self, body, mime="application/json", status=200, extra=None, length=None):
        self.send_response(status)
        if mime:
            self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body) if length is None else length))
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
(root / "port").write_text(str(server.server_port))
server.serve_forever()
