#!/usr/bin/env python3
"""Strict collection URLs and resource-level DAV errors; isolated loopback fixture."""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, unquote
from xml.sax.saxutils import escape

LOG = sys.argv[1]
COUNTS = {}
LOCK = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def record(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "authorization": self.headers.get("Authorization"), "depth": self.headers.get("Depth")}) + "\n")
    def do_PROPFIND(self):
        self.record()
        path = urlsplit(self.path).path
        name = unquote(path[len("/dav/"):].strip("/"))
        with LOCK:
            COUNTS[name] = COUNTS.get(name, 0) + 1
            attempt = COUNTS[name]
        if name == "loop":
            self.send(301, headers={"Location": path + "/"}); return
        redirects = {
            "foreign": "http://other.invalid/dav/foreign/", "outside": "/outside/",
            "query": path + "/?token=anything", "fragment": path + "/#part",
            "userinfo": "http://user@127.0.0.1:%s%s/" % (self.server.server_port, path),
            "scheme-change": "https://127.0.0.1:%s%s/" % (self.server.server_port, path),
            "encoded": path.replace("encoded", "%65ncoded") + "/",
            "temporary": path + "/", "network-path": "//other.invalid" + path + "/"
        }
        if name in redirects:
            self.send(302 if name == "temporary" else 301, headers={"Location": redirects[name]}); return
        if name == "slow-canonical" and path.endswith("/"):
            time.sleep(20)
        if name in ["folder", "folder/nested", "资料 空间", "permanent", "slow-canonical"] and not path.endswith("/"):
            # Both absolute and path-relative Location forms refer to exactly the same collection.
            location = "http://127.0.0.1:%s%s/" % (self.server.server_port, path) if name == "folder" else path.rsplit("/", 1)[-1] + "/"
            self.send(308 if name == "permanent" else 301, headers={"Location": location}); return
        if name in ["retry-stat", "retry-list", "retry-write", "retry-recovery"] and attempt == 1:
            response = '<d:response><d:href>%s</d:href><d:status>HTTP/1.1 503 Unavailable</d:status></d:response>' % escape(path)
        elif name.startswith("status-"):
            status = int(name.split("-")[1])
            response = '<d:response><d:href>%s</d:href><d:status>HTTP/1.1 %s Error</d:status></d:response>' % (escape(path), status)
        elif name == "no-properties":
            response = '<d:response><d:href>%s</d:href></d:response>' % escape(path)
        else:
            is_dir = not name or name in ["folder", "folder/nested", "资料 空间", "permanent", "retry-list", "retry-write"]
            response = self.item(path, is_dir)
            if self.headers.get("Depth") == "1" and name == "folder":
                response += self.item("/dav/folder/child.txt", False)
                response += self.item("/dav/folder/nested/", True)
        body = ('<d:multistatus xmlns:d="DAV:">' + response + '</d:multistatus>').encode()
        self.send(207, body, {"Content-Type": "application/xml"})
    def item(self, path, directory):
        props = '<d:resourcetype>%s</d:resourcetype><d:getcontentlength>5</d:getcontentlength><d:getetag>"v1"</d:getetag>' % ('<d:collection/>' if directory else '')
        return '<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>' % (escape(path), props)
    def do_GET(self): self.record(); self.send(200, b"hello", {"ETag": '"v1"'})
    def do_PUT(self): self.record(); self.send(201)
    def do_DELETE(self): self.record(); self.send(204)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
