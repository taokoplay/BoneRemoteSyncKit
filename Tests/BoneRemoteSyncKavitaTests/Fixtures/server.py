"""Pinned Kavita v0.9.1.4 wire fixture. Fake credentials; localhost and Python stdlib only."""
import base64
import io
import json
import pathlib
import sys
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = pathlib.Path(sys.argv[1])
LOCK = threading.Lock()
PROGRESS = {}


def archive(members):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        for name, value in members:
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            z.writestr(info, value)
    return out.getvalue()


RAW = archive([("mimetype", b"application/epub+zip"), ("part.xhtml", b"<html><body>Fixture</body></html>")])
PARTS = [b"PK\x03\x04first-cbz", b"PK\x03\x04second-cbz"]
ZIP = archive([("first.cbz", PARTS[0]), ("second.cbz", PARTS[1])])
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0N8AAAAASUVORK5CYII=")
IMAGE_ZIP = archive([("page.png", PNG)])
PDF = b"%PDF-1.4\nfixture-pdf\n%%EOF"
for name, data in [("raw.epub", RAW), ("archive.zip", ZIP), ("image.zip", IMAGE_ZIP), ("raw.pdf", PDF), ("cover.png", PNG)]:
    (ROOT / name).write_bytes(data)


def mode():
    try:
        return json.loads((ROOT / "mode.json").read_text())
    except (OSError, ValueError):
        return {}


def series(sid=12):
    return {"id": sid, "libraryId": 2 if mode().get("relation") == "series" else 1,
            "name": "Fixture " + str(sid), "originalName": "Original", "sortName": "fixture",
            "format": 3 if sid == 12 else 91, "pages": 12, "pagesRead": 1,
            "wordCount": 5000000000, "userRating": 4.5, "folderPath": "/private/server/books"}


def chapter(cid):
    fmt, names, blobs = {
        34: (3, ["book.epub"], [RAW]), 35: (1, ["first.cbz", "second.cbz"], PARTS),
        36: (0, ["page.png"], [PNG]), 37: (4, ["book.pdf"], [PDF])
    }[cid]
    return {"id": cid, "volumeId": 99 if mode().get("relation") == "chapter" else 23,
            "title": "Chapter", "titleName": "Display", "range": "1.5", "minNumber": 1.5,
            "maxNumber": 1.5, "sortOrder": 1.5, "pages": 3, "pagesRead": 0, "format": fmt,
            "summary": "Fixture summary", "isbn": "9780000000000", "language": "en",
            "wordCount": 5000000001, "writers": [{"id": 1, "name": "Writer", "roles": []}],
            "genres": [{"id": 2, "title": "Adventure"}], "tags": [{"id": 3, "title": "Fixture"}],
            "files": [{"id": cid * 10 + n, "filePath": "/secret/server/library/" + name,
                       "pages": 3, "bytes": len(blob), "format": fmt, "extension": pathlib.Path(name).suffix}
                      for n, (name, blob) in enumerate(zip(names, blobs))]}


def volume():
    value = {"id": 23, "seriesId": 99 if mode().get("relation") == "volume" else 12,
             "name": "Volume", "minNumber": 1.5, "maxNumber": 2.5, "pages": 12,
             "chapters": [chapter(cid) for cid in [34, 35, 36, 37]]}
    if mode().get("relation") == "membership":
        value["chapters"] = value["chapters"][1:]
    return value


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send(self, value, status=200, headers=None, content_type="application/json"):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for key, val in (headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def route(self):
        url = urlsplit(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"null")
        with LOCK:
            with (ROOT / "requests.jsonl").open("a") as out:
                out.write(json.dumps({"path": url.path, "query": query, "body": body, "method": self.command,
                                      "authorization": self.headers.get("Authorization"), "key": self.headers.get("X-API-Key")}) + "\n")
        if not url.path.startswith("/kavita/api/"):
            return self.send(b"mount required", 404, content_type="text/plain")
        path = url.path[len("/kavita/api/"):]
        options = mode()
        if path == options.get("delayPath"):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (ROOT / "release").exists():
                time.sleep(0.01)
        if path == options.get("statusPath"):
            status = options.get("status", 500)
            return self.send(b"fictional-sensitive-error", status, content_type="text/plain")
        if path == "Account/login":
            if body != {"username": "fixture-user", "password": "fixture-password"}:
                return self.send(b"wrong fictional password", 401, content_type="text/plain")
            # Login's id is intentionally unusable; the adapter must obtain real identity via GET Account.
            return self.send({"id": 0, "token": "fixture-jwt", "refreshToken": "fixture-refresh"})
        key, auth = self.headers.get("X-API-Key"), self.headers.get("Authorization")
        if key not in ["fixture-key", "other-key"] and auth not in ["Bearer fixture-jwt", "Bearer refreshed-jwt", "Bearer other-jwt"]:
            return self.send(b"", 401, content_type=None)
        if key and auth or "apiKey" in query:
            return self.send(b"mixed credentials", 400, content_type="text/plain")
        if path == "Account":
            return self.send({"id": 43 if key == "other-key" or auth == "Bearer other-jwt" else 42,
                              "username": "fixture-user", "roles": ["Login", "Download"],
                              "kavitaVersion": "0.9.1.4", "token": None, "refreshToken": None,
                              "apiKey": "different-opds-key"})
        if path == "Account/refresh-token":
            if body != {"token": "fixture-jwt", "refreshToken": "fixture-refresh"}:
                return self.send({"message": "wrong fictional refresh"}, 401)
            return self.send({"token": "other-jwt" if options.get("refreshIdentity") else "refreshed-jwt",
                              "refreshToken": "refreshed-refresh"})
        if path == "Library/libraries":
            return self.send([{"id": 1, "name": "Books", "type": 2, "includeInSearch": True, "folders": ["/secret/server"]}])
        if path == "Series/v2":
            statements = body.get("statements", [])
            if len(statements) not in [2, 3] or statements[:2] != [
                    {"field": 19, "comparison": 0, "value": statements[0].get("value")},
                    {"field": 34, "comparison": 0, "value": "false"}] or not isinstance(statements[0]["value"], str):
                return self.send(b"bad filters", 400, content_type="text/plain")
            if body.get("combination") != 1 or body.get("limitTo") != 0 or body.get("sortOptions") != {"sortField": 1, "isAscending": True}:
                return self.send(b"bad sort", 400, content_type="text/plain")
            if len(statements) == 3 and (statements[2]["field"], statements[2]["comparison"]) != (1, 7):
                return self.send(b"bad search", 400, content_type="text/plain")
            items = [series(i) for i in [12, 13, 14]]
            if statements[0]["value"] != "1" or len(statements) == 3 and statements[2]["value"] == "empty":
                items = []
            page, size = int(query["PageNumber"]), int(query["PageSize"])
            total = len(items)
            result = items[(page - 1) * size:page * size]
            paging = {"currentPage": page, "itemsPerPage": size, "totalItems": total, "totalPages": (total + size - 1) // size}
            bad = options.get("pagination")
            if bad == "wrongPage": paging["currentPage"] += 1
            if bad == "wrongSize": paging["itemsPerPage"] += 1
            if bad == "wrongTotal": paging["totalPages"] += 1
            if bad == "negative": paging["totalItems"] = -1
            if bad == "partial": result = []
            if bad == "duplicate": result = [series(12), series(12)][:size]
            if bad == "wrongLibrary" and result: result[0]["libraryId"] = 7
            headers = {} if bad == "missing" else {"Pagination": "broken" if bad == "malformed" else json.dumps(paging)}
            return self.send(result, headers=headers)
        if path == "Series/volumes": return self.send([volume()])
        if path == "Series/volume": return self.send(volume())
        if path == "Series/chapter":
            cid = int(query["chapterId"])
            if cid not in [34, 35, 36, 37]: return self.send(b"", 404, content_type=None)
            value = chapter(cid)
            if options.get("malformedChapter"): value.pop("pages")
            if options.get("wrongChapterID"): value["id"] += 10
            return self.send(value)
        if path.startswith("Series/"):
            sid = int(path.split("/")[1])
            if sid == 404: return self.send(b"access hidden", 404, content_type="text/plain")
            return self.send(series(sid))
        if path.startswith("Image/") or path in ["Reader/image", "Reader/thumbnail"]:
            if path == "Reader/image" and query.get("chapterId") == "37" and query.get("extractPdf") != "true":
                return self.send(b"extract required", 400, content_type="text/plain")
            if path == "Reader/thumbnail" and "pageNum" not in query:
                return self.send(b"pageNum required", 400, content_type="text/plain")
            return self.send(PNG, content_type="image/png")
        if path == "Download/chapter":
            cid = int(query["chapterId"])
            blob, name, mime = {34: (RAW, "book.epub", "application/epub+zip"),
                                35: (ZIP, "chapter.zip", "application/octet-stream"),
                                36: (IMAGE_ZIP, "chapter.zip", "application/octet-stream"),
                                37: (PDF, "book.pdf", "application/pdf")}[cid]
            return self.send(blob, headers={"Content-Disposition": 'attachment; filename="' + name + '"'}, content_type=mime)
        if path == "Reader/get-progress":
            cid = int(query["chapterId"])
            value = dict(PROGRESS.get(cid, {"chapterId": cid, "libraryId": 0, "seriesId": 0, "volumeId": 0,
                                             "pageNum": 0, "bookScrollId": None, "lastModifiedUtc": "0001-01-01T00:00:00"}))
            if options.get("badProgress"): value["seriesId"] = 88
            if options.get("overflowProgress"): value["pageNum"] = 4
            return self.send(value)
        if path == "Reader/progress":
            if not all(k in body for k in ["libraryId", "seriesId", "volumeId", "chapterId", "pageNum"]):
                return self.send(b"required fields", 400, content_type="text/plain")
            if (body["libraryId"], body["seriesId"], body["volumeId"]) != (1, 12, 23) or not 0 <= body["pageNum"] <= 3:
                return self.send(b"wrong ancestry or page", 400, content_type="text/plain")
            if body["pageNum"] != 0 or body["chapterId"] in PROGRESS:
                PROGRESS[body["chapterId"]] = dict(body, lastModifiedUtc="2026-01-01T00:00:00Z")
            return self.send(b"", content_type=None)
        if path.startswith("Book/") and path.endswith("book-info"):
            return self.send({"bookTitle": "Fixture book", "seriesName": "Fixture", "seriesFormat": 3,
                              "libraryId": 1, "seriesId": 12, "volumeId": 23, "pages": 3})
        if path.startswith("Book/") and path.endswith("chapters"):
            return self.send([{"title": "Start", "part": "part.xhtml#start", "page": 0,
                               "children": [{"title": "Next", "part": "next.xhtml", "page": 1, "children": []}]}])
        return self.send(b"unknown fixture route", 404, content_type="text/plain")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
(ROOT / "port").write_text(str(server.server_port))
server.serve_forever()
