import sys, json, re, threading, urllib.parse, os, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

log, scenario = sys.argv[1:3]
lock = threading.Lock()
BASE = 'http://127.0.0.1:'
nextid = [0]

def newid():
    nextid[0] += 1
    return 'i%d' % nextid[0]

# id -> {name, parent, folder, content, etag}
nodes = {'root': dict(name='root', parent=None, folder=True, content=b'', etag='"v1"')}
sessions = {}
nextsession = [0]

def new_session(parent, name, behavior):
    nextsession[0] += 1
    sid = 's%d' % nextsession[0]
    sessions[sid] = dict(parent=parent, name=name, content=bytearray(), total=None, behavior=behavior,
                          put_count=0, committed=False)
    return sid

def sessionjson(s):
    n = len(s['content'])
    ranges = [] if s['committed'] else (["0-"] if n == 0 else ["%d-" % n])
    return dict(uploadUrl=BASE + str(server.server_port) + '/upload-session/' + s['id'],
                expirationDateTime='2030-01-01T00:00:00Z', nextExpectedRanges=ranges)

def add(name, parent='root', folder=False, content=b''):
    i = newid()
    nodes[i] = dict(name=name, parent=parent, folder=folder, content=content, etag='"v1"')
    return i

add('keep.txt', content=b'hello')
add('docs', folder=True)

def children(pid):
    return [i for i, n in nodes.items() if n['parent'] == pid]

def bypath(path):
    if path in ('', '/'):
        return 'root'
    cur = 'root'
    for part in [p for p in path.split('/') if p]:
        match = [c for c in children(cur) if nodes[c]['name'] == part]
        if not match:
            return None
        cur = match[0]
    return cur

def pathof(i):
    parts = []
    while nodes[i]['parent'] is not None:
        parts.append(nodes[i]['name'])
        i = nodes[i]['parent']
    return '/' + '/'.join(reversed(parts))

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def record(self, body=''):
        with lock, open(log, 'a') as f:
            f.write(json.dumps(dict(method=self.command, path=self.path, body=body,
                                    authorization=self.headers.get('Authorization'),
                                    cookie=self.headers.get('Cookie'),
                                    contentType=self.headers.get('Content-Type'),
                                    contentRange=self.headers.get('Content-Range'))) + '\n')
    def reply(self, status, value, headers=None):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header('Content-Length', len(data)); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def itemjson(self, i):
        n = nodes[i]
        value = dict(id=i, name=n['name'], eTag=n['etag'], parentReference=dict(driveId='D', id=n['parent']),
                     lastModifiedDateTime='2026-10-20T00:00:00Z')
        if n['folder']:
            value['folder'] = {}
        else:
            value['size'] = len(n['content'])
            value['file'] = dict(mimeType='application/octet-stream')
            value['@microsoft.graph.downloadUrl'] = BASE + str(self.server.server_port) + '/download/' + i
        return value
    def body_bytes(self):
        n = int(self.headers.get('Content-Length', 0))
        return self.rfile.read(n) if n else b''
    def target(self):
        p = urllib.parse.urlsplit(self.path)
        return p, urllib.parse.unquote(p.path)
    def do_GET(self):
        self.record(); parsed, path = self.target()
        if path.startswith('/upload-session/'):
            if os.path.exists(log + '.hold-status'):
                for _ in range(200):
                    if not os.path.exists(log + '.hold-status'): break
                    time.sleep(.025)
            sid = path.rsplit('/', 1)[-1]
            if scenario == 'upload-expired' or sid not in sessions:
                return self.reply(404, dict(error=dict(code='uploadSessionNotFound')))
            s = sessions[sid]; s['id'] = sid
            if scenario == 'upload-malformed-ranges':
                return self.reply(200, dict(uploadUrl=BASE + str(server.server_port) + '/upload-session/' + sid,
                                           expirationDateTime='2030-01-01T00:00:00Z',
                                           nextExpectedRanges=['0-10', '10-20']))
            if scenario == 'upload-noncontiguous-ranges' and s['put_count'] == 0:
                return self.reply(200, dict(uploadUrl=BASE + str(server.server_port) + '/upload-session/' + sid,
                                           expirationDateTime='2030-01-01T00:00:00Z',
                                           nextExpectedRanges=['0-10', '20-']))
            if scenario == 'upload-session-401':
                return self.reply(401, dict(error=dict(code='unauthenticated')))
            if scenario == 'upload-session-409':
                return self.reply(409, dict(error=dict(code='conflict')))
            if scenario == 'upload-session-412':
                return self.reply(412, dict(error=dict(code='preconditionFailed')))
            if scenario == 'upload-session-500':
                return self.reply(500, dict(error=dict(code='serverError')))
            value = sessionjson(s)
            if scenario == 'upload-no-progress': value['nextExpectedRanges'] = ['0-']
            if scenario == 'upload-status-without-url': value.pop('uploadUrl')
            return self.reply(200, value)
        if path.startswith('/download/'):
            i = path.rsplit('/', 1)[-1]
            if i not in nodes: return self.reply(404, b'')
            return self.reply(200, nodes[i]['content'])
        if path == '/v1.0/me/drive': return self.reply(200, dict(id='D', driveType='personal'))
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^/]+)/children', path)
        if m:
            pid = m.group(1)
            if pid not in nodes: return self.reply(404, dict(error=dict(code='itemNotFound')))
            return self.reply(200, dict(value=[self.itemjson(c) for c in children(pid)]))
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^/]+)', path)
        if m:
            i = m.group(1)
            if i not in nodes: return self.reply(404, dict(error=dict(code='itemNotFound')))
            return self.reply(200, self.itemjson(i))
        m = re.fullmatch(r'/v1\.0/drives/D/root(:/.*)?', path)
        if m:
            i = bypath(m.group(1)[1:] if m.group(1) else '')
            if i is None: return self.reply(404, dict(error=dict(code='itemNotFound')))
            return self.reply(200, self.itemjson(i))
        return self.reply(404, dict(error=dict(code='itemNotFound')))
    def do_POST(self):
        body = self.body_bytes().decode(); self.record(body)
        parsed, path = self.target()
        if path == '/oauth/token':
            return self.reply(200, dict(access_token='REFRESHED', refresh_token='ROTATED', expires_in=3600, token_type='Bearer'))
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^:]+):/(.+):/createUploadSession', path)
        if m:
            payload = json.loads(body)
            parent, name = m.group(1), urllib.parse.unquote(m.group(2))
            if parent not in nodes or not nodes[parent]['folder']:
                return self.reply(404, dict(error=dict(code='itemNotFound')))
            if scenario == 'upload-create-429':
                return self.reply(429, dict(error=dict(code='tooManyRequests')), {'Retry-After': '120'})
            sid = new_session(parent, name, payload.get('item', {}).get('@microsoft.graph.conflictBehavior', 'fail'))
            sessions[sid]['id'] = sid
            if scenario == 'upload-create-unknown':
                self.send_response(200); self.send_header('Content-Length', '100'); self.end_headers()
                self.close_connection = True; return
            return self.reply(200, sessionjson(sessions[sid]))
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^/]+)/children', path)
        if not m: return self.reply(404, dict(error=dict(code='itemNotFound')))
        pid = m.group(1)
        if pid not in nodes: return self.reply(404, dict(error=dict(code='itemNotFound')))
        payload = json.loads(body)
        name = payload['name']
        existing = [c for c in children(pid) if nodes[c]['name'] == name]
        behavior = payload.get('@microsoft.graph.conflictBehavior', 'fail')
        if existing and behavior == 'fail':
            return self.reply(409, dict(error=dict(code='nameAlreadyExists')))
        i = existing[0] if existing else add(name, pid, folder='folder' in payload)
        return self.reply(201, self.itemjson(i))
    def do_PUT(self):
        parsed, path = self.target()
        if path.startswith('/upload-session/'):
            payload = self.body_bytes(); self.record('<%d bytes>' % len(payload))
            sid = path.rsplit('/', 1)[-1]
            if sid not in sessions or scenario == 'upload-expired':
                return self.reply(404, dict(error=dict(code='uploadSessionNotFound')))
            s = sessions[sid]; s['id'] = sid; s['put_count'] += 1
            if scenario == 'upload-retry-after':
                return self.reply(429, dict(error=dict(code='tooManyRequests')), {'Retry-After': '120'})
            if scenario == 'upload-no-progress':
                return self.reply(202, sessionjson(s))
            if scenario == 'upload-429' and s['put_count'] == 1:
                return self.reply(429, dict(error=dict(code='tooManyRequests')), {'Retry-After': '0'})
            if scenario == 'upload-416-always' or (scenario == 'upload-416' and s['put_count'] == 1):
                return self.reply(416, dict(error=dict(code='invalidRange')))
            if scenario == 'upload-put-409':
                return self.reply(409, dict(error=dict(code='conflict')))
            if scenario == 'upload-put-412':
                return self.reply(412, dict(error=dict(code='preconditionFailed')))
            if scenario == 'upload-put-500':
                return self.reply(500, dict(error=dict(code='serverError')))
            raw_range = self.headers.get('Content-Range', '')
            match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', raw_range)
            if not match:
                return self.reply(416, dict(error=dict(code='invalidRange')))
            start, end, total = [int(x) for x in match.groups()]
            if end - start + 1 != len(payload) or start != len(s['content']):
                return self.reply(416, dict(error=dict(code='invalidRange')))
            s['total'] = total
            s['content'].extend(payload)
            final = end + 1 == total
            if not final:
                value = sessionjson(s)
                if scenario == 'upload-status-without-url': value.pop('uploadUrl')
                return self.reply(202, value)
            existing = [c for c in children(s['parent']) if nodes[c]['name'] == s['name']]
            if existing and s['behavior'] == 'fail':
                return self.reply(409, dict(error=dict(code='nameAlreadyExists')))
            if existing:
                i = existing[0]; nodes[i]['content'] = bytes(s['content']); nodes[i]['etag'] = '"v2"'
            else:
                i = add(s['name'], s['parent'], content=bytes(s['content']))
            s['committed'] = True
            if scenario == 'upload-commit-unknown':
                value = self.itemjson(i)
                self.send_response(201); self.send_header('Connection', 'close')
                self.send_header('Content-Length', len(json.dumps(value).encode()) + 10); self.end_headers()
                self.close_connection = True
                return
            value = self.itemjson(i)
            if scenario == 'upload-wrong-target': value['name'] = 'other.bin'
            return self.reply(201, value)
        payload = self.body_bytes(); self.record('<%d bytes>' % len(payload))
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^/]+):/(.+):/content', path)
        if not m: return self.reply(404, dict(error=dict(code='itemNotFound')))
        pid, name = m.group(1), m.group(2)
        if pid not in nodes or not nodes[pid]['folder']:
            return self.reply(404, dict(error=dict(code='itemNotFound')))
        if scenario == 'upload-forbidden': return self.reply(403, dict(error=dict(code='accessDenied')))
        if scenario == 'upload-refresh' and self.headers.get('Authorization') != 'Bearer REFRESHED':
            return self.reply(401, dict(error=dict(code='unauthenticated')))
        query = urllib.parse.parse_qs(parsed.query)
        behavior = (query.get('@microsoft.graph.conflictBehavior') or ['replace'])[0]
        existing = [c for c in children(pid) if nodes[c]['name'] == name]
        if existing and behavior == 'fail':
            return self.reply(409, dict(error=dict(code='nameAlreadyExists')))
        if existing:
            i = existing[0]
            nodes[i]['content'] = payload; nodes[i]['etag'] = '"v2"'
        else:
            i = add(name, pid, content=payload)
        return self.reply(201, self.itemjson(i))
    def do_PATCH(self):
        body = self.body_bytes().decode(); self.record(body)
        parsed, path = self.target()
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^/]+)', path)
        if not m or m.group(1) not in nodes:
            return self.reply(404, dict(error=dict(code='itemNotFound')))
        i = m.group(1)
        payload = json.loads(body)
        parent = payload.get('parentReference', {}).get('id', nodes[i]['parent'])
        if parent not in nodes or not nodes[parent]['folder']:
            return self.reply(404, dict(error=dict(code='itemNotFound')))
        name = payload.get('name', nodes[i]['name'])
        if any(c != i and nodes[c]['name'] == name for c in children(parent)):
            return self.reply(409, dict(error=dict(code='nameAlreadyExists')))
        nodes[i]['parent'] = parent; nodes[i]['name'] = name
        return self.reply(200, self.itemjson(i))
    def do_DELETE(self):
        self.record()
        parsed, path = self.target()
        if path.startswith('/upload-session/'):
            sid = path.rsplit('/', 1)[-1]
            if sid not in sessions: return self.reply(404, dict(error=dict(code='uploadSessionNotFound')))
            sessions.pop(sid, None)
            if scenario == 'upload-abort-unknown':
                self.close_connection = True; self.connection.close(); return
            self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers(); return
        m = re.fullmatch(r'/v1\.0/drives/D/items/([^/]+)', path)
        if not m or m.group(1) not in nodes:
            return self.reply(404, dict(error=dict(code='itemNotFound')))
        i = m.group(1)
        if scenario == 'delete-forbidden': return self.reply(403, dict(error=dict(code='accessDenied')))
        stack = [i]
        while stack:
            cur = stack.pop()
            stack.extend(children(cur))
            nodes.pop(cur, None)
        self.send_response(204); self.end_headers()

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
