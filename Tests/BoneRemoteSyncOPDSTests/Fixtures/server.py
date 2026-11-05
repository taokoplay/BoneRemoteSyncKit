#!/usr/bin/env python3
"""Local synthetic OPDS fixture. No external network or real credentials."""
import base64
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from xml.sax.saxutils import escape, quoteattr

workspace = sys.argv[1]
lock = threading.Lock()
active = 0
maximum = 0
ATOM = 'http://www.w3.org/2005/Atom'
ACQ = 'http://opds-spec.org/acquisition'
PAYLOAD = b'PK\x03\x04opds-test-content' * 10000


def entry(target='/files/book.epub', detail=False):
    links = ''.join('<link rel="%s" href=%s type=%s/>' % (ACQ, quoteattr(url), quoteattr(mime)) for url, mime in [
        (target, 'application/octet-stream' if target.endswith('generic.pdf') else 'application/epub+zip'), ('/files/book.pdf', 'application/pdf'), ('/files/book.cbz', 'application/vnd.comicbook+zip')])
    if not detail:
        links += '<link rel="alternate" href="/entry" type="application/atom+xml;type=entry;profile=opds-catalog"/>'
    return '<entry xmlns="%s" xmlns:dc="http://purl.org/dc/terms/"><id>urn:book:1</id><title>示例书</title><updated>2026-11-01T00:00:00Z</updated><author><name>作者</name></author><dc:language>zh</dc:language><summary>%s</summary>%s</entry>' % (ATOM, '完整简介' if detail else '摘要', links)


def feed(items='', links='', title='书库'):
    return ('<feed xmlns="%s"><id>urn:feed</id><title>%s</title><updated>2026-11-01T00:00:00Z</updated>%s%s</feed>' % (ATOM, escape(title), links, items)).encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def send(self, data, mime='application/atom+xml;profile=opds-catalog', status=200, headers=None):
        self.send_response(status)
        if mime is not None:
            self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global active, maximum
        path = urlsplit(self.path).path
        query = parse_qs(urlsplit(self.path).query)
        with lock:
            with open(workspace + '/requests.jsonl', 'a') as log:
                log.write(json.dumps({'path': self.path, 'authorization': self.headers.get('Authorization'), 'cookie': self.headers.get('Cookie')}) + '\n')
        try:
            if path == '/compat/metadata':
                items = entry().replace('2026-11-01T00:00:00Z', '2026-11-01T00:00:00')
                data = feed(items).replace(b'<updated>2026-11-01T00:00:00Z</updated>', b'')
                return self.send(data)
            if path == '/compat/mime':
                mime = query.get('type', ['text/html'])[0]
                shape = query.get('shape', ['atom'])[0]
                data = feed(entry())
                if shape == 'html':
                    data = b'<html><body>Login</body></html>'
                elif shape == 'foreign':
                    data = b'<feed xmlns="urn:not-atom"><title>fake</title></feed>'
                elif shape == 'entity':
                    data = b'<!DOCTYPE feed [<!ENTITY ex SYSTEM "file:///must-not-open">]>' + data
                elif shape == 'large':
                    data = b'x' * 4096
                return self.send(data, None if mime == 'missing' else mime)
            if path == '/compat/direct':
                kind = query.get('kind', ['raw'])[0]
                template = '/search?q={searchTerms}&count={count}&fixed=a%26b&slash=%2F'
                if kind == 'encoded':
                    template = template.replace('{', '%7b').replace('}', '%7D')
                elif kind == 'namespaced':
                    template = template.replace('{searchTerms}', '{os:searchTerms}')
                elif kind == 'relative':
                    template = '../search?q={searchTerms}'
                elif kind == 'cross':
                    template = 'http://localhost:%d/search?q={searchTerms}' % self.server.server_port
                links = '<link xmlns:os="http://a9.com/-/spec/opensearch/1.1/" xml:base="/compat/" rel="search" type="application/atom+xml" href=%s/>' % quoteattr(template)
                return self.send(feed(entry(), links))
            if path == '/auth' and self.headers.get('Authorization') != 'Basic ' + base64.b64encode(b'user:pass').decode():
                return self.send(b'', status=401, headers={'WWW-Authenticate': 'Basic realm="fixture"'})
            if path.startswith('/status/'):
                return self.send(b'', status=int(path.rsplit('/', 1)[1]), headers={'Retry-After': '2'})
            if path == '/redirect':
                return self.send(b'', status=302, headers={'Location': '/catalog/root'})
            if path == '/redirect-loop':
                return self.send(b'', status=302, headers={'Location': '/redirect-loop'})
            if path == '/cross-download':
                return self.send(b'', status=302, headers={'Location': 'http://localhost:%d/files/book.epub' % self.server.server_port})
            if path == '/cross-feed':
                return self.send(b'', status=302, headers={'Location': 'http://localhost:%d/catalog/root' % self.server.server_port})
            if path == '/entry':
                return self.send(entry(detail=True).encode(), 'application/atom+xml;type=entry;profile=opds-catalog')
            if path == '/search.xml':
                return self.send(b'<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/"><Url type="application/atom+xml;profile=opds-catalog" template="/search?q={searchTerms}&amp;count={count}&amp;x={unknown?}"/></OpenSearchDescription>', 'application/opensearchdescription+xml')
            if path == '/search':
                return self.send(feed(entry(), title=query.get('q', [''])[0]))
            if path == '/page2':
                return self.send(feed('', '<link rel="next" href="/page3"/>'))
            if path == '/page3':
                return self.send(feed(entry()))
            if path == '/cycle':
                return self.send(feed('', '<link rel="next" href="/cycle"/>'))
            if path == '/large':
                return self.send(b'x' * 4096)
            if path == '/slow-feed':
                time.sleep(0.8)
                return self.send(feed(entry()))
            if path in ['/html', '/fake-html']:
                return self.send(b'  <!DOCTYPE html><html><body>Login</body></html>', 'text/html' if path == '/html' else 'application/epub+zip')
            if path == '/short':
                self.send_response(200)
                self.send_header('Content-Type', 'application/epub+zip')
                self.send_header('Content-Length', '1000')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(b'PKshort'); self.wfile.flush(); self.close_connection = True
                return
            if path.startswith('/files/') or path in ['/slow', '/unknown']:
                with lock:
                    active += 1; maximum = max(maximum, active)
                    with open(workspace + '/maximum.txt', 'w') as result:
                        result.write(str(maximum))
                try:
                    self.send_response(200)
                    mime = 'application/pdf' if path.endswith('.pdf') else 'application/vnd.comicbook+zip' if path.endswith('.cbz') else 'application/epub+zip'
                    self.send_header('Content-Type', mime)
                    if path != '/unknown':
                        self.send_header('Content-Length', str(len(PAYLOAD)))
                    else:
                        self.send_header('Connection', 'close'); self.close_connection = True
                    self.end_headers()
                    for offset in range(0, len(PAYLOAD), 4096):
                        if path == '/slow':
                            time.sleep(0.02)
                        self.wfile.write(PAYLOAD[offset:offset + 4096]); self.wfile.flush()
                finally:
                    with lock:
                        active -= 1
                return
            target = query.get('target', ['/files/book.epub'])[0]
            links = '<link rel="next" href="/page2"/><link rel="search" href="/search.xml" type="application/opensearchdescription+xml"/>'
            nav = '<entry><id>urn:category</id><title>分类</title><updated>2026-11-01T00:00:00Z</updated><link href="/catalog/root" type="application/atom+xml"/></entry>'
            self.send(feed(nav + entry(target), links))
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(workspace + '/port', 'w') as port:
    port.write(str(server.server_port))
server.serve_forever()
