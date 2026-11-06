"""Komga 1.30 contract fixture. stdlib only; never contacts a real service."""
import base64
import copy
import datetime
import json
import pathlib
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = pathlib.Path(sys.argv[1])
MOUNT = "/proxy/komga/"
STAMP = "2026-01-02T03:04:05Z"
FILE = b"PK\x03\x04Komga fixture publication\x00\xff"
JPEG = base64.b64decode("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAB//2Q==")
LOCK = threading.Lock()
PROGRESS = {}
READIUM = {}
ME_COUNT = {}


def progress(page, completed=False, device=None):
    device = device or {"id": "", "name": ""}
    return dict(page=page, completed=completed, readDate=STAMP, created=STAMP,
                lastModified=STAMP, deviceId=device["id"], deviceName=device["name"])


def book(identifier):
    epub = identifier in ("epub", "epubzero", "divina")
    return dict(id=identifier, seriesId="s1", libraryId="l1", seriesTitle="Fixture series",
                name=identifier + (".epub" if epub else ".cbz"), number=1,
                url="/private/server/books/DO-NOT-EXPOSE.cbz", sizeBytes=len(FILE),
                created=STAMP, lastModified="2026-01-02T03:04:05.123Z", deleted=False,
                oneshot=False, fileHash="not-a-strong-version",
                media=dict(status="READY", mediaType="application/epub+zip" if epub else "application/zip",
                           pagesCount=3, epubDivinaCompatible=identifier == "divina", epubIsKepub=False,
                           mediaProfile="EPUB" if epub else "PDF" if identifier == "pdf" else "DIVINA"),
                metadata=dict(title="Fixture " + identifier, number="1", numberSort=1.5, summary="Summary",
                              releaseDate="2024-02-29", authors=[dict(name="Author", role="writer")], tags=["tag"]),
                readProgress=copy.deepcopy(PROGRESS.get(identifier, progress(0) if identifier == "epubzero" else None)))


def series(identifier):
    return dict(id=identifier, libraryId="l1", name="Fixture series " + identifier,
                url="/private/server/DO-NOT-EXPOSE", booksCount=3, booksReadCount=0,
                booksUnreadCount=3, booksInProgressCount=0, created=STAMP, lastModified=STAMP,
                metadata=dict(title="Series " + identifier, titleSort=identifier, status="ONGOING",
                              publisher="Publisher", language="en"),
                booksMetadata=dict(authors=[dict(name="Author", role="writer")], releaseDate=None),
                deleted=False, oneshot=False)


def condition_matches(item, condition):
    if "allOf" in condition:
        return all(condition_matches(item, part) for part in condition["allOf"])
    for key, value in condition.items():
        if key not in ("libraryId", "seriesId") or value.get("operator") != "is":
            raise ValueError("invalid condition")
        if item[key] != value["value"]:
            return False
    return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def respond(self, status=200, body=None, mime="application/json"):
        data = b"" if body is None else body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with LOCK:
            with (ROOT / "requests.jsonl").open("a") as output:
                output.write(json.dumps(dict(method=self.command, path=self.path,
                                            headers=dict(self.headers), body=body.decode())) + "\n")
        parsed = urlsplit(self.path)
        if not parsed.path.startswith(MOUNT):
            return self.respond(404, {"secret": "sensitive-server-body"})
        path = parsed.path[len(MOUNT):].split("/")
        query = parse_qs(parsed.query)
        key = self.headers.get("X-API-Key")
        basic = "Basic " + base64.b64encode(b"reader@example.invalid:fixture-password").decode()
        allowed_keys = ("fixture-key", "nodownload-key", "switch-key", "slow-connect-key", "other-key")
        if key not in allowed_keys and self.headers.get("Authorization") != basic:
            return self.respond(401, b"sensitive-server-body invalid credentials", "text/plain")
        if self.headers.get("Cookie") or (key and self.headers.get("Authorization")):
            return self.respond(400, {"secret": "sensitive-server-body unexpected credential mode"})
        if path == ["api", "v2", "users", "me"] and self.command == "GET":
            if key == "slow-connect-key":
                (ROOT / "connect-started").touch()
                time.sleep(1.5)
            with LOCK:
                ME_COUNT[key] = ME_COUNT.get(key, 0) + 1
                count = ME_COUNT[key]
            user_id = "u2" if key == "other-key" or (key == "switch-key" and count > 1) else "u1"
            return self.respond(body=dict(id=user_id, email="reader@example.invalid",
                                          roles=["USER", "PAGE_STREAMING"] + ([] if key == "nodownload-key" else ["FILE_DOWNLOAD"]),
                                          sharedAllLibraries=True, sharedLibrariesIds=[], labelsAllow=[], labelsExclude=[]))
        if path[:3] == ["api", "v1", "libraries"] and self.command == "GET":
            library = dict(id="l1", name="Fixture library", unavailable=False, root="/private/server/DO-NOT-EXPOSE")
            if len(path) == 3:
                return self.respond(body=[library])
            if path[3] == "l1":
                return self.respond(body=library)
            if path[3] == "wrong-id":
                return self.respond(body=library)
            return self.respond(404, {"secret": "sensitive-server-body"})
        if len(path) < 4 or path[:2] != ["api", "v1"] or path[2] not in ("series", "books"):
            return self.respond(404, {"secret": "sensitive-server-body"})
        kind, identifier = path[2:4]
        if identifier == "list" and self.command == "POST":
            if self.headers.get("Content-Type") != "application/json":
                return self.respond(400, {"secret": "wrong content type"})
            try:
                search = json.loads(body)
                page = int(query["page"][0])
                size = int(query["size"][0])
                items = [series("s1"), series("s2")] if kind == "series" else [book("b1"), book("b2"), book("epub")]
                items = [item for item in items if condition_matches(item, search.get("condition", {}))]
                term = search.get("fullTextSearch", "")
                if term and not term.startswith("__"):
                    items = [item for item in items if term.lower() in item["metadata"]["title"].lower()]
                total = len(items)
                items = items[page * size:(page + 1) * size]
                pages = (total + size - 1) // size
                result = dict(content=items, number=page, size=size, totalElements=total, totalPages=pages,
                              numberOfElements=len(items), first=page == 0, last=page >= max(0, pages - 1), empty=not items)
                if term == "__bad-page": result["number"] = page + 1
                if term == "__bad-total": result["totalElements"] = -1
                if term == "__partial": result.pop("content")
                if term == "__wrong-parent" and items: items[0]["libraryId"] = "l2"
                if term == "__wrong-series" and items: items[0]["seriesId"] = "s2"
                if term == "__duplicate" and len(items) > 1: items[1]["id"] = items[0]["id"]
                return self.respond(body=result)
            except (ValueError, KeyError):
                return self.respond(400, {"secret": "sensitive-server-body"})
        if identifier.startswith("http"):
            status = int(identifier[4:])
            return self.respond(status, b"<html>sensitive-server-body</html>", "text/html")
        if identifier == "malformed":
            return self.respond(body=b'{"id": "sensitive-server-body"')
        if identifier == "slow":
            (ROOT / "metadata-started").touch()
            time.sleep(1.5)
        if len(path) == 4 and self.command == "GET":
            result = series(identifier) if kind == "series" else book(identifier)
            if identifier == "wrong-id": result["id"] = "someone-else"
            if identifier == "negative": result["media"]["pagesCount"] = -1
            if identifier == "bad-date": result["created"] = "yesterday"
            return self.respond(body=result)
        if path[4:] == ["thumbnail"] and self.command == "GET":
            if identifier == "missing-cover": return self.respond(404, {})
            return self.respond(body=JPEG, mime="image/jpeg")
        if kind != "books": return self.respond(404, {})
        if path[4:] == ["pages"] and self.command == "GET":
            values = [dict(number=n, fileName=str(n) + ".jpg", mediaType="image/jpeg", width=1,
                           height=1, sizeBytes=len(JPEG), size="fixture") for n in range(1, 4)]
            if identifier == "bad-pages": values[1]["number"] = 1
            if identifier in ("epub", "epubzero"): values = []
            return self.respond(body=values)
        if len(path) == 6 and path[4] == "pages" and self.command == "GET":
            if query != {"contentNegotiation": ["false"], "convert": ["jpeg"]}:
                return self.respond(body=b"%PDF-fixture", mime="application/pdf")
            return self.respond(body=JPEG, mime="image/jpeg")
        if path[4:] == ["file"] and self.command == "GET":
            if key == "nodownload-key": return self.respond(403, {})
            if identifier == "slow-file":
                (ROOT / "file-started").touch()
                time.sleep(1.5)
            return self.respond(body=FILE, mime="application/zip")
        if path[4:] == ["read-progress"]:
            if self.command == "DELETE":
                PROGRESS.pop(identifier, None)
                READIUM.pop(identifier, None)
                return self.respond(204)
            if self.command != "PATCH": return self.respond(405, {"secret": "GET read-progress does not exist"})
            value = json.loads(body)
            if value.get("completed") is True and set(value) == {"completed"}:
                PROGRESS[identifier] = progress(3, True)
            elif set(value) == {"page"} and 1 <= value["page"] <= 3 and identifier != "epub":
                PROGRESS[identifier] = progress(value["page"], value["page"] == 3)
            else:
                return self.respond(400, {"violations": [{"message": "sensitive-server-body"}]})
            READIUM[identifier] = dict(modified=STAMP, device={"id": "", "name": ""}, locator={})
            return self.respond(204)
        if path[4:] == ["progression"]:
            if self.command == "GET":
                if identifier not in READIUM: return self.respond(204)
                return self.respond(body=READIUM[identifier], mime="application/vnd.readium.progression+json")
            if self.command == "PUT":
                value = json.loads(body)
                if self.headers.get("Content-Type") != "application/vnd.readium.progression+json":
                    return self.respond(400, {})
                timestamp = lambda text: datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
                if identifier in READIUM and timestamp(value["modified"]) <= timestamp(READIUM[identifier]["modified"]):
                    return self.respond(409, {"message": "sensitive-server-body"})
                loc = value["locator"]
                if identifier.startswith("epub") and (loc["href"] != "OEBPS/chapter.xhtml" or "progression" not in loc["locations"]):
                    return self.respond(400, {"message": "sensitive-server-body"})
                READIUM[identifier] = value
                PROGRESS[identifier] = progress(0 if identifier.startswith("epub") else loc["locations"]["position"], device=value["device"])
                return self.respond(204)
        return self.respond(404, {})

    do_GET = do_POST = do_PATCH = do_DELETE = do_PUT = handle_request


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(ROOT / "port").write_text(str(server.server_port))
server.serve_forever(poll_interval=0.05)
