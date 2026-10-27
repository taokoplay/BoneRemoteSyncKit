#!/usr/bin/env python3
"""Controlled read-only WebDAV fixture. Binds only IPv4 loopback, never user data."""
import base64
import json
import sys
import time
import threading
import hashlib
import socket
import struct

STATE_LOCK = threading.Lock()
ATTEMPTS = {}
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit
from xml.sax.saxutils import escape

LOG = sys.argv[1]
STATE_FILE = sys.argv[2] if len(sys.argv) > 2 else None

def fixture_etag(base, item, fallback):
    if base == "mutable" and item and STATE_FILE:
        try:
            with open(STATE_FILE) as state:
                return '"v2"' if state.read().strip() == "v2" else fallback
        except FileNotFoundError:
            pass
    return fallback

SMALL = b"abcdefghijklmnopqrstuvwxyz"
LARGE = bytes(range(256)) * 12288
RECOVERY = b"".join(hashlib.sha256(str(i).encode()).digest() for i in range(98304))
FILES = {
    "hello.txt": SMALL, "empty.txt": b"", "large.bin": LARGE,
    "big.bin": bytes(range(256)) * 131072,
    "slow.bin": LARGE, "ignore-range.txt": SMALL, "bad-range.txt": SMALL,
    "changed.txt": SMALL, "no-etag.txt": SMALL, "weak.txt": SMALL,
    "truncated.txt": SMALL, "资料/a #?%.txt": "你好，WebDAV".encode(),
    "folder/child.txt": b"child", ".hidden": b"hidden", "redirect.txt": SMALL,
    "unknown.txt": SMALL, "encoded.txt": SMALL, "wrong-etag.txt": SMALL,
    "cut-once.bin": RECOVERY, "cut-always.bin": RECOVERY, "complete-cut.bin": RECOVERY,
    "force416.txt": SMALL,
}


def response(href, directory=False, size=None, etag='"v1"', failed=False):
    props = "<d:resourcetype>" + ("<d:collection/>" if directory else "") + "</d:resourcetype>"
    if size is not None:
        props += "<d:getcontentlength>%s</d:getcontentlength>" % size
    if etag:
        props += "<d:getetag>%s</d:getetag>" % escape(etag)
    props += "<d:creationdate>2026-10-19T01:02:03.125Z</d:creationdate><d:getlastmodified>Tue, 20 Oct 2026 01:00:00 GMT</d:getlastmodified><d:getcontenttype>application/octet-stream</d:getcontenttype>"
    return "<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 %s</d:status></d:propstat></d:response>" % (escape(href), props, "404 Not Found" if failed else "200 OK")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def record(self):
        body_size = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(body_size) if body_size else b""
        with open(LOG, "a") as out:
            out.write(json.dumps({"method": self.command, "path": self.path, "authorization": self.headers.get("Authorization"), "depth": self.headers.get("Depth"), "asksCreationDate": b"creationdate" in body, "range": self.headers.get("Range"), "ifMatch": self.headers.get("If-Match")}) + "\n")

    def send(self, status, body=b"", headers=None):
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        path = unquote(urlsplit(self.path).path)
        pieces = path.strip("/").split("/", 1)
        base = pieces[0]
        item = pieces[1].strip("/") if len(pieces) == 2 else ""
        with STATE_LOCK:
            key = (self.command, path)
            count = ATTEMPTS.get(key, 0) + 1
            ATTEMPTS[key] = count
        if base == "retry-always" or (base == "retry-once" and count == 1) or (base == "retry-twice" and count <= 2):
            self.send(503)
            return None
        if base == "retry-date" and item and count == 1:
            self.send(503, headers={"Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"})
            return None
        if base == "retry-501":
            self.send(501)
            return None
        if base in ["retry-after", "retry-after-long"] and count == 1:
            self.send(429, headers={"Retry-After": "60" if base == "retry-after-long" else "1"})
            return None
        if base == "auth" and self.headers.get("Authorization") != "Basic " + base64.b64encode(b"alice:secret").decode():
            self.send(401, headers={"WWW-Authenticate": 'Basic realm="fixture"'})
            return None
        if base == "redirect" or item == "redirect.txt":
            self.send(302, headers={"Location": "http://127.0.0.1:%s/dav/" % self.server.server_port})
            return None
        codes = {"forbidden": 403, "missing": 404, "limited": 429, "broken": 503, "precondition": 412}
        if item in codes:
            self.send(codes[item], headers={"Retry-After": "7"})
            return None
        return base, item

    def do_PROPFIND(self):
        self.record()
        route = self.route()
        if route is None:
            return
        base, item = route
        if base == "badxml":
            self.send(207, b"<html>not DAV</html>")
            return
        if base == "oversized":
            self.send(207, b"x" * (16 * 1024 * 1024 + 1))
            return
        if item and item not in FILES and item not in ["folder", "资料"]:
            self.send(404)
            return
        directory = not item or item in ["folder", "资料"]
        if base == "file-root":
            directory = False
        href = "/%s/" % base + quote(item, safe="/") + ("/" if item and directory else "")
        size = None if directory or item == "unknown.txt" else len(FILES.get(item, SMALL))
        etag = 'W/"v1"' if item == "weak.txt" else (None if item == "no-etag.txt" else '"v1"')
        etag = fixture_etag(base, item, etag)
        entries = [response(href, directory, size, etag)]
        if self.headers.get("Depth") == "1" and directory:
            names = ["folder", "资料", "hello.txt", "empty.txt", ".hidden"] if not item else (["folder/child.txt"] if item == "folder" else ["资料/a #?%.txt"])
            for name in names:
                is_dir = name in ["folder", "资料"]
                entries.append(response("/%s/" % base + quote(name, safe="/") + ("/" if is_dir else ""), is_dir, None if is_dir else len(FILES[name])))
            # Bad hrefs and failures must not become visible traversable items.
            if base not in ["coverage-complete", "coverage-duplicate", "coverage-missing", "coverage-hidden-failed"]:
                entries += [response("https://evil.example/%s/steal" % base, True), response("/%s/%s/injected/grandchild" % (base, quote(item, safe="/")), True), response("/%s/failed" % base, failed=True), response("/%s/../escape" % base), response("/%s/a%%2fb" % base)]
            if base == "coverage-duplicate":
                entries.append(response("/%s/hello.txt" % base, size=999))
            if base == "coverage-missing":
                entries.append(response("/%s/missing-props" % base).replace("<d:resourcetype></d:resourcetype>", ""))
            if base == "coverage-hidden-failed":
                entries.append(response("/%s/.hidden-failure" % base, failed=True))
        if base == "no-creation":
            entries = [entry.replace("<d:creationdate>2026-10-19T01:02:03.125Z</d:creationdate>", "") for entry in entries]
        xml = '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">' + "".join(entries) + "</d:multistatus>"
        self.send(207, xml.encode(), {"Content-Type": "application/xml; charset=utf-8"})

    def do_GET(self):
        self.record()
        route = self.route()
        if route is None:
            return
        base, item = route
        with STATE_LOCK:
            attempt = ATTEMPTS[(self.command, unquote(urlsplit(self.path).path))]
        if item not in FILES:
            self.send(404)
            return
        payload = FILES[item]
        etag = 'W/"v1"' if item == "weak.txt" else ('"v2"' if item in ["changed.txt", "wrong-etag.txt"] else '"v1"')
        etag = fixture_etag(base, item, etag)
        if item not in ["weak.txt", "wrong-etag.txt"] and self.headers.get("If-Match") not in [None, etag]:
            self.send(412)
            return
        headers = {"Content-Type": "application/octet-stream", "Accept-Ranges": "bytes"}
        if item != "no-etag.txt":
            headers["ETag"] = etag
        if item == "encoded.txt":
            headers["Content-Encoding"] = "gzip"
        status = 200
        range_header = self.headers.get("Range")
        if range_header and item == "force416.txt":
            self.send(416)
            return
        if range_header and item != "ignore-range.txt":
            offset = int(range_header.removeprefix("bytes=").removesuffix("-")) if sys.version_info >= (3, 9) else int(range_header[6:-1])
            if offset >= len(payload):
                self.send(416, headers={"Content-Range": "bytes */%d" % len(payload)})
                return
            status = 206
            start = offset + 1 if item == "bad-range.txt" else offset
            headers["Content-Range"] = "bytes %d-%d/%d" % (start, len(payload) - 1, len(payload))
            payload = payload[offset:]
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        full_cut = item == "complete-cut.bin" and attempt == 1
        if full_cut:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(len(payload) + (10 if item == "truncated.txt" else 0)))
        if item == "truncated.txt":
            self.send_header("Connection", "close")
        self.end_headers()
        cut = item == "cut-always.bin" or (item in ["cut-once.bin", "complete-cut.bin"] and attempt == 1)
        if cut and item != "complete-cut.bin":
            payload = payload[:256 * 1024 + 16384]
        try:
            for offset in range(0, len(payload), 16384):
                chunk = payload[offset:offset + 16384]
                if full_cut:
                    self.wfile.write(("%x\r\n" % len(chunk)).encode() + chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
                self.wfile.flush()
                if item == "slow.bin":
                    time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass
        if cut and base == "gated":
            from pathlib import Path
            deadline = time.monotonic() + 5
            while not Path(LOG + ".cut-ready").exists() and time.monotonic() < deadline:
                time.sleep(0.005)
        if item == "truncated.txt" or cut:
            self.close_connection = True
            try:
                if full_cut:
                    time.sleep(0.1)
                    self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    self.connection.close()
                else:
                    self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
