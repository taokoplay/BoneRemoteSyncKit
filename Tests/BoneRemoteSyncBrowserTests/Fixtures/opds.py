"""Unified browser OPDS fixture: loopback only, fake credentials and content."""
import base64
import json
import pathlib
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

root = pathlib.Path(sys.argv[1])
lock = threading.Lock()
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')


def book(number, detail=False):
    links = ''
    if number == 1:
        links = '<link rel="http://opds-spec.org/image/thumbnail" type="image/png" href="/cover?token=fixture-private-link"/>'
        if detail:
            links += '<link rel="http://opds-spec.org/acquisition/open-access" type="text/plain" href="/file/text?token=fixture-private-link"/>'
            links += '<link rel="http://opds-spec.org/acquisition/open-access" type="application/pdf" href="/file/pdf?token=fixture-private-link"/>'
        else:
            links += '<link rel="alternate" type="application/atom+xml;type=entry" href="/detail/1"/>'
            links += '<link rel="http://opds-spec.org/acquisition/open-access" type="application/pdf" href="/file/pdf?token=fixture-private-link"/>'
    else:
        links = '<link rel="http://opds-spec.org/acquisition/buy" type="text/html" href="/buy"/>'
    return f'<entry xmlns="http://www.w3.org/2005/Atom"><id>urn:book:{number}</id><title>Book {number}</title><author><name>Author</name></author><summary type="html">&lt;p&gt;Summary&lt;/p&gt;</summary>{links}</entry>'


def feed(entries, more=False, search=True):
    links = '<link rel="search" type="application/atom+xml" href="/search?q={searchTerms}"/>' if search else ''
    if more:
        links += '<link rel="next" type="application/atom+xml" href="/next"/>'
    return ('<feed xmlns="http://www.w3.org/2005/Atom"><id>urn:fixture:feed</id><title>Fixture</title>' + links + entries + '</feed>').encode()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with lock:
            with (root / 'requests.jsonl').open('a') as log:
                log.write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization')}) + '\n')
        if self.headers.get('Authorization') != 'Basic ' + base64.b64encode(b'reader:fixture').decode():
            return self.reply(b'Unauthorized', 'text/plain', 401)
        url = urlsplit(self.path)
        path = url.path
        if path in ['/root', '/no-search']:
            nav = '<entry><id>urn:navigation</id><title>Category</title><link rel="subsection" type="application/atom+xml" title="First" href="/category?token=fixture-private-link"/><link rel="subsection" type="application/atom+xml" title="Second" href="/category-two"/></entry>'
            return self.reply(feed(nav + book(1) + book(2), more=True, search=path != '/no-search'))
        if path == '/next':
            return self.reply(feed(book(3)))
        if path in ['/category', '/category-two']:
            return self.reply(feed(book(1)))
        if path == '/search':
            return self.reply(feed(book(1) if parse_qs(url.query).get('q') == ['Fixture & Book'] else ''))
        if path == '/detail/1':
            return self.reply(book(1, detail=True).encode(), 'application/atom+xml;type=entry')
        if path == '/cover':
            return self.reply(PNG, 'image/png')
        if path == '/file/text':
            return self.reply(b'browser fixture book', 'text/plain')
        if path == '/file/pdf':
            return self.reply(b'%PDF-1.7\nfixture', 'application/pdf')
        return self.reply(b'Not Found', 'text/plain', 404)

    def reply(self, body, mime='application/atom+xml', status=200):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
