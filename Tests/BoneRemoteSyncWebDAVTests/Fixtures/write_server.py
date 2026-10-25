#!/usr/bin/env python3
"""In-memory RFC-style write fixture; localhost only, no access to user files."""
import base64
import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, unquote, quote
from xml.sax.saxutils import escape

LOG = sys.argv[1]
LOCK = threading.RLock()
ITEMS = {"/": None, "/hello.txt": b"original", "/folder": None, "/folder/child.txt": b"child"}


def etag(data):
    return '"' + hashlib.sha256(data or b"").hexdigest() + '"'


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def begin(self):
        parsed = unquote(urlsplit(self.path).path).strip("/").split("/", 1)
        self.base = parsed[0]
        self.item = "/" + (parsed[1].rstrip("/") if len(parsed) > 1 else "")
        with LOCK, open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                               "destination": self.headers.get("Destination"), "overwrite": self.headers.get("Overwrite"),
                               "depth": self.headers.get("Depth"), "contentType": self.headers.get("Content-Type"),
                               "ifNoneMatch": self.headers.get("If-None-Match"), "ifMatch": self.headers.get("If-Match"),
                               "authorization": self.headers.get("Authorization")}) + "\n")
        if self.command == "PUT" and self.item == "/early":
            self.send(201)
            self.close_connection = True
            return False
        self.body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.base == "auth" and self.headers.get("Authorization") != "Basic " + base64.b64encode(b"alice:secret").decode():
            self.send(401, headers={"WWW-Authenticate": 'Basic realm="fixture"'})
            return False
        if self.command not in ["PROPFIND", "GET"]:
            codes = {"/forbidden": 403, "/locked": 423, "/limited": 429, "/broken": 503, "/unsupported": 405}
            if self.item in codes:
                self.send(codes[self.item], headers={"Retry-After": "7"})
                return False
            if self.item == "/redirect":
                self.send(307, headers={"Location": "http://127.0.0.1:%s/dav/stolen" % self.server.server_port})
                return False
            if self.item == "/partial":
                self.send(207, b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/partial/child</d:href><d:status>HTTP/1.1 423 Locked</d:status></d:response></d:multistatus>')
                return False
            if self.item in ["/slow", "/deadline"]:
                time.sleep(20 if self.item == "/deadline" else 2)
        return True

    def do_PROPFIND(self):
        if not self.begin():
            return
        with LOCK:
            if self.item not in ITEMS:
                self.send(404)
                return
            names = [self.item]
            if self.headers.get("Depth") == "1" and ITEMS[self.item] is None:
                names += [p for p in ITEMS if p != self.item and (p.rsplit("/", 1)[0] or "/") == self.item]
            entries = []
            for p in names:
                data = ITEMS[p]
                href = "/" + self.base + quote(p, safe="/") + ("/" if p != "/" and data is None else "")
                props = "<d:resourcetype>" + ("<d:collection/>" if data is None else "") + "</d:resourcetype>"
                if data is not None:
                    props += "<d:getcontentlength>%d</d:getcontentlength>" % len(data)
                if self.base != "no-etag":
                    props += "<d:getetag>%s</d:getetag>" % escape(etag(data))
                entries.append("<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>" % (escape(href), props))
            self.send(207, ('<d:multistatus xmlns:d="DAV:">' + "".join(entries) + '</d:multistatus>').encode())

    def do_GET(self):
        if not self.begin():
            return
        with LOCK:
            if self.item not in ITEMS or ITEMS[self.item] is None:
                self.send(404)
            else:
                self.send(200, ITEMS[self.item], {"ETag": etag(ITEMS[self.item])})

    def do_PUT(self):
        if not self.begin():
            return
        with LOCK:
            if self.base == "put-race":
                ITEMS[self.item] = b"concurrent writer"
            exists = self.item in ITEMS
            if self.headers.get("If-None-Match") == "*" and exists:
                self.send(412)
                return
            if self.headers.get("If-Match") and (not exists or self.headers["If-Match"] != etag(ITEMS[self.item])):
                self.send(412)
                return
            parent = self.item.rsplit("/", 1)[0] or "/"
            if parent not in ITEMS or ITEMS[parent] is not None:
                self.send(409)
            elif exists and ITEMS[self.item] is None:
                self.send(405)
            else:
                ITEMS[self.item] = self.body
                self.send(204 if exists else 201, headers={"ETag": etag(self.body)})

    def do_MKCOL(self):
        if not self.begin():
            return
        with LOCK:
            parent = self.item.rsplit("/", 1)[0] or "/"
            if self.base == "mkcol-race":
                ITEMS[self.item] = None
                self.send(405)
            elif self.item in ITEMS:
                self.send(405)
            elif parent not in ITEMS or ITEMS[parent] is not None:
                self.send(409)
            else:
                ITEMS[self.item] = None
                self.send(201)

    def do_DELETE(self):
        if not self.begin():
            return
        with LOCK:
            if self.item not in ITEMS:
                self.send(404)
                return
            for p in list(ITEMS):
                if p == self.item or p.startswith(self.item + "/"):
                    del ITEMS[p]
            self.send(204)

    def relocate(self):
        if not self.begin():
            return
        target = urlsplit(self.headers.get("Destination", ""))
        prefix = "/" + self.base
        decoded = unquote(target.path).rstrip("/")
        if target.netloc != self.headers.get("Host") or not decoded.startswith(prefix + "/"):
            self.send(400)
            return
        destination = decoded[len(prefix):]
        with LOCK:
            if self.item not in ITEMS:
                self.send(404)
            elif destination in ITEMS and self.headers.get("Overwrite") == "F":
                self.send(412)
            elif (destination.rsplit("/", 1)[0] or "/") not in ITEMS:
                self.send(409)
            else:
                tree = {p: data for p, data in ITEMS.items() if p == self.item or p.startswith(self.item + "/")}
                for p, data in tree.items():
                    ITEMS[destination + p[len(self.item):]] = data
                    if self.command == "MOVE":
                        del ITEMS[p]
                self.send(201)

    do_MOVE = relocate
    do_COPY = relocate


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
