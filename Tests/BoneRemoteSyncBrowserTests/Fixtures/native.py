"""Independent unified-browser fixture: synthetic data, localhost, Python stdlib only."""
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
STAMP = "2026-01-02T03:04:05Z"
QUERY = "Fixture & chapter"
RAW = b"PK\x03\x04native-publication"
AUDIO = {"101": b"ID3native-track-101", "102": b"ID3native-track-102", "201": b"ID3native-track-201"}
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0N8AAAAASUVORK5CYII=")
JPEG = base64.b64decode("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAB//2Q==")
out = io.BytesIO()
with zipfile.ZipFile(out, "w") as archive:
    archive.writestr("first.cbz", RAW)
    archive.writestr("second.cbz", RAW)
ZIP = out.getvalue()
(ROOT / "original.bin").write_bytes(RAW)
(ROOT / "archive.zip").write_bytes(ZIP)


def state():
    try:
        return json.loads((ROOT / "state.json").read_text())
    except (OSError, ValueError):
        return {}


def komga_series(sid="s1"):
    return dict(id=sid, libraryId="l2" if state().get("moved") else "l1", name="Series " + sid,
                booksCount=2, metadata=dict(title="Fixture series " + sid, language="en", tags=["series-tag"]),
                created=STAMP, booksMetadata=dict(authors=[dict(name="Writer", role="writer")]))


def komga_book(bid="b1"):
    epub = bid == "b2"
    return dict(id=bid, libraryId="l2" if state().get("moved") else "l1", seriesId="s1", seriesTitle="Series",
                name=bid + (".epub" if epub else ".cbz"), number=1, sizeBytes=len(RAW),
                url="/private/server/secret.cbz", created=None if epub else STAMP, lastModified=None,
                media=dict(status="READY", mediaType="application/epub+zip" if epub else "application/zip",
                           pagesCount=4, mediaProfile="EPUB" if epub else "DIVINA"),
                metadata=dict(title="Fixture " + bid, summary="<p>Book summary</p>" if not epub else "Plain summary",
                              releaseDate="2024-02-29", authors=[dict(name="Writer", role="writer")], tags=["book-tag"]),
                readProgress=dict(page=2, completed=False, readDate=STAMP, created=STAMP,
                                  lastModified=STAMP, deviceId="", deviceName=""))


def kavita_series(sid=12):
    return dict(id=sid, libraryId=2 if state().get("moved") else 1, name="Fixture series " + str(sid),
                format=3, pages=8, created="2024-01-01T12:00:00", lastChapterAddedUtc=STAMP)


def kavita_chapter(cid):
    fmt = 3 if cid == 34 else 1 if cid == 35 else 4
    names = ["first.cbz", "second.cbz"] if cid == 35 else ["book.epub" if cid == 34 else "book.pdf"]
    return dict(id=cid, volumeId=23, titleName="Chapter " + str(cid), pages=0 if cid == 36 else 4, pagesRead=0 if cid == 36 else 2,
                format=fmt, summary="<p>Chapter summary</p>", language="en", releaseDate="2024",
                writers=[dict(id=1, name="Writer")], tags=[dict(id=2, title="chapter-tag")],
                createdUtc="2024-01-01T12:00:00", lastModifiedUtc=STAMP,
                files=[dict(id=cid * 10 + n, filePath="/private/server/" + name, bytes=len(RAW), format=fmt)
                       for n, name in enumerate(names)])


def kavita_volume(vid=23):
    return dict(id=vid, seriesId=12, name="Volume " + str(vid), pages=8,
                chapters=[kavita_chapter(cid) for cid in (34, 35, 36)] if vid == 23 else [])


def abs_file(fid, index=1):
    audio = fid in AUDIO
    value = dict(ino=fid, mimeType="audio/mpeg" if audio else "application/epub+zip",
                 metadata=dict(filename=fid + (".mp3" if audio else ".epub"), size=len(AUDIO[fid] if audio else RAW),
                               path="/private/server/secret", relPath="secret"))
    if audio:
        value.update(index=index, duration=30)
    return value


def abs_track(item, fid, index=1):
    return dict(index=index, startOffset=(index - 1) * 30, duration=30, title=fid + ".mp3",
                contentUrl="/api/items/" + item + "/file/" + fid, mimeType="audio/mpeg", codec="mp3")


def abs_item(i="book-1", mini=False):
    podcast = i == "podcast-1"
    library = "podcasts" if podcast else "books"
    result = dict(id=i, libraryId="moved" if state().get("moved") else library, mediaType="podcast" if podcast else "book",
                  path="/private/server", media=dict(id="media-" + i, tags=["item-tag"], duration=60,
                  metadata=dict(title="Fixture " + i, subtitle="Subtitle", description="<p>Rich description</p>",
                                authors=[dict(id="author", name="Writer")], narrators=["Narrator"],
                                language="en", publishedYear="2024")))
    if not mini:
        if podcast:
            result["libraryFiles"] = [abs_file("201")]
            result["media"]["episodes"] = [dict(id="episode-1", libraryItemId=i, podcastId="media-" + i,
                title="Episode one", description="<p>Episode notes</p>", publishedAt=1700000000000, duration=30,
                audioFile=abs_file("201"), audioTrack=abs_track(i, "201")),
                dict(id="episode-2", libraryItemId=i, podcastId="media-" + i, title="Undownloaded episode")]
        elif i == "book-2":
            result["libraryFiles"] = []
            result["media"].update(audioFiles=[], tracks=[], chapters=[])
        else:
            result["libraryFiles"] = [abs_file("101"), abs_file("102", 2), abs_file("ebook")]
            result["media"].update(audioFiles=[abs_file("101"), abs_file("102", 2)],
                                   tracks=[abs_track(i, "101"), abs_track(i, "102", 2)], chapters=[])
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, value, status=200, mime="application/json", headers=None):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        for name, content in (headers or {}).items():
            self.send_header(name, content)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_PATCH(self):
        self.route()

    def route(self):
        parsed = urlsplit(self.path)
        parts = parsed.path.strip("/").split("/")
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw) if raw else {}
        with LOCK:
            with (ROOT / "requests.jsonl").open("a") as log:
                log.write(json.dumps(dict(method=self.command, path=parsed.path, query=query, body=raw.decode())) + "\n")
        opts = state()
        if opts.get("delayPath") == parsed.path:
            (ROOT / "delayed").touch()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (ROOT / "release").exists():
                time.sleep(0.01)
        if opts.get("missingCover") and (parts[-1] in ("thumbnail", "cover") or "-cover" in parts[-1]):
            return self.send({}, 404)
        download = not opts.get("noDownload")
        service, path = parts[0], "/".join(parts[1:])
        if service == "komga":
            if self.headers.get("X-API-Key") != "fixture-key":
                return self.send({}, 401)
            if path == "api/v2/users/me":
                return self.send(dict(id="u1", email="fixture@example.invalid", roles=["USER", "PAGE_STREAMING"] + (["FILE_DOWNLOAD"] if download else []),
                                      sharedAllLibraries=True, sharedLibrariesIds=[]))
            if path.startswith("api/v1/libraries"):
                value = dict(id="l1", name="Comics", unavailable=False, root="/private/server")
                return self.send([value] if path == "api/v1/libraries" else value)
            if path.endswith("/list"):
                values = [komga_series()] if "series" in path else [komga_book("b1"), komga_book("b2")]
                if body.get("fullTextSearch") not in (None, QUERY):
                    return self.send({}, 400)
                condition = body.get("condition", {})
                conditions = condition.get("allOf", [condition])
                for condition in conditions:
                    for field, rule in condition.items():
                        values = [value for value in values if value.get(field) == rule.get("value")]
                page, size, total = int(query["page"]), int(query["size"]), len(values)
                values = values[page * size:(page + 1) * size]
                pages = (total + size - 1) // size
                return self.send(dict(content=values, number=page, size=size, totalElements=total, totalPages=pages,
                                      numberOfElements=len(values), first=page == 0, last=page >= pages - 1, empty=not values))
            if parts[-1] == "thumbnail":
                return self.send(JPEG, mime="image/jpeg")
            if parts[-1] == "file":
                return self.send(RAW, mime="application/zip")
            if len(parts) == 5:
                return self.send(komga_series(parts[-1]) if parts[-2] == "series" else komga_book(parts[-1]))
        if service == "kavita":
            if self.headers.get("X-API-Key") != "fixture-key":
                return self.send({}, 401)
            if path == "api/Account":
                return self.send(dict(id=42, username="fixture", roles=["Login"] + (["Download"] if download else [])))
            if path == "api/Library/libraries":
                return self.send([dict(id=1, name="Books", type=2, includeInSearch=True)])
            if path == "api/Series/v2":
                statements = body.get("statements", [])
                if not any(s.get("field") == 19 and s.get("value") == "1" for s in statements):
                    return self.send({}, 400)
                if any(s.get("field") == 1 and s.get("value") != QUERY for s in statements):
                    return self.send({}, 400)
                page, size = int(query["PageNumber"]), int(query["PageSize"])
                values = [kavita_series(12), kavita_series(13)][(page - 1) * size:page * size]
                return self.send(values, headers={"Pagination": json.dumps(dict(currentPage=page, itemsPerPage=size, totalItems=2, totalPages=(2 + size - 1) // size))})
            if path == "api/Series/volumes":
                return self.send([kavita_volume(), kavita_volume(24)])
            if path == "api/Series/volume":
                return self.send(kavita_volume(int(query["volumeId"])))
            if path == "api/Series/chapter":
                return self.send(kavita_chapter(int(query["chapterId"])))
            if path.startswith("api/Series/"):
                return self.send(kavita_series(int(parts[-1])))
            if path.startswith("api/Image/"):
                return self.send(PNG, mime="image/png")
            if path == "api/Download/chapter":
                return self.send(ZIP if query["chapterId"] == "35" else RAW, mime="application/zip")
        if service == "abs":
            if self.headers.get("Authorization") != "Bearer fixture-key":
                return self.send({}, 401)
            if path == "api/me":
                return self.send(dict(id="u1", username="fixture", type="user", isActive=True, librariesAccessible=[],
                                      permissions=dict(download=download, update=False, upload=False, delete=False, accessAllLibraries=True)))
            if path == "api/libraries":
                return self.send(dict(libraries=[dict(id="books", name="Books", mediaType="book"), dict(id="podcasts", name="Podcasts", mediaType="podcast")]))
            if path.startswith("api/libraries/"):
                podcast = parts[-2] == "podcasts"
                if parts[-1] == "search":
                    if query.get("q") != QUERY:
                        return self.send({}, 400)
                    return self.send({"podcast" if podcast else "book": [dict(libraryItem=abs_item("podcast-1" if podcast else "book-1", True))]})
                values = [abs_item("podcast-1", True)] if podcast else [abs_item("book-1", True), abs_item("book-2", True)]
                page, size, total = int(query["page"]), int(query["limit"]), len(values)
                return self.send(dict(results=values[page * size:(page + 1) * size], page=page, limit=size, total=total))
            if path.startswith("api/me/progress/"):
                return self.send(dict(id="progress", userId="u1", libraryItemId=parts[4], episodeId=parts[5] if len(parts) > 5 else None,
                                      duration=60, progress=0.5, currentTime=30, isFinished=False, lastUpdate=1700000000000))
            if path.startswith("api/items/"):
                if len(parts) == 4:
                    return self.send(abs_item(parts[3]))
                if parts[4] == "cover":
                    return self.send(PNG, mime="image/png")
                if parts[4] == "file":
                    return self.send(AUDIO.get(parts[5], RAW), mime="audio/mpeg" if parts[5] in AUDIO else "application/epub+zip")
        return self.send({}, 404)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
(ROOT / "port").write_text(str(server.server_port))
server.serve_forever()
