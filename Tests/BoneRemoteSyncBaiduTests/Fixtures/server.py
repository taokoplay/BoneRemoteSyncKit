#!/usr/bin/env python3
"""Synthetic official Baidu API contracts; loopback only, fictitious tokens and files."""
import hashlib
import json
import os
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from email.parser import BytesParser
from email.policy import default

workspace, scenario = sys.argv[1:3]
root = '/apps/Fixture'
lock = threading.RLock()
files = {}
uploads = {}
next_id = 9007199254741000
payload = 'hello 百度\n'.encode()


def put(path, directory=False, data=b''):
    global next_id
    next_id += 1
    value = dict(fs_id=next_id, path=path, server_filename=path.rsplit('/', 1)[-1], isdir=int(directory),
                 size=len(data), server_ctime=1700000000, server_mtime=1700000001, data=data)
    files[path] = value
    return value


put(root, True)
put(root + '/folder', True)
put(root + '/a.txt', data=payload)
put(root + '/.hidden', data=b'hidden')
put(root + '/文档 +?.txt', data=payload)
put(root + '/folder/nested.txt', data=payload)


def meta(value, port, dlink=False):
    item = {k: v for k, v in value.items() if k != 'data'}
    item['md5'] = hashlib.md5(value['data']).hexdigest()
    if dlink and not item['isdir']:
        item['dlink'] = 'http://127.0.0.1:%d/download/%d?signature=a%%2Fb%%2Bz' % (port, item['fs_id'])
        if scenario == 'evil-dlink': item['dlink'] = 'https://evil.example/file'
    if scenario == 'string-ids': item['fs_id'] = str(item['fs_id'])
    return item


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def send(self, value, status=200, content_type='application/json', headers=None):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self): self.handle_request()
    def do_POST(self): self.handle_request()
    def handle_request(self):
        query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        path = urlsplit(self.path).path
        method = query.get('method', [''])[0]
        raw = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        form = parse_qs(raw.decode(errors='replace'), keep_blank_values=True) if 'urlencoded' in self.headers.get('Content-Type', '') else {}
        def q(key, fallback=''): return query.get(key, [fallback])[0]
        def f(key, fallback=''): return form.get(key, [fallback])[0]
        with lock:
            with open(os.path.join(workspace, 'requests.jsonl'), 'a') as out:
                out.write(json.dumps(dict(method=method, verb=self.command, path=path, query=query, form=form,
                                          agent=self.headers.get('User-Agent'), authorization=self.headers.get('Authorization'),
                                          cookie=self.headers.get('Cookie'), rawQuery=urlsplit(self.path).query)) + '\n')
        try:
            if path.startswith('/download/'):
                if not q('access_token'): return self.send(dict(errno=31045, request_id=1), status=401)
                if scenario == 'download-redirect':
                    return self.send(b'', status=302, headers={'Location': self.path.replace('/download/', '/content/')})
                if scenario == 'evil-redirect':
                    return self.send(b'', status=302, headers={'Location': 'https://evil.example/steal'})
                return self.download(path)
            if path.startswith('/content/'): return self.download(path)
            if q('access_token') == 'expired': return self.send(dict(errno=20016))
            if scenario == 'auth': return self.send(dict(errno=20017))
            if method == 'uinfo':
                if scenario == 'slow-connect': time.sleep(0.4)
                return self.send(dict(errno=0, uk=222 if q('access_token') == 'other-user' else 111, netdisk_name='Fixture'))
            if scenario == 'rate-limit': return self.send(dict(errno=20012))
            if scenario == 'api-redirect': return self.send(b'', status=302, headers={'Location': '/elsewhere'})
            if method == 'meta':
                with lock:
                    item = files.get(q('path'))
                    if item is None: return self.send(dict(errno=-9))
                    return self.send(dict(errno=0, list=[meta(item, self.server.server_port)]))
            if method == 'filemetas':
                ids = json.loads(q('fsids'))
                with lock:
                    values = [meta(v, self.server.server_port, q('dlink') == '1') for v in files.values() if v['fs_id'] in ids]
                    if scenario == 'outside-id' and values: values[0]['path'] = '/private/secret'
                    return self.send(dict(errno=0, list=values))
            if method == 'list':
                if scenario == 'slow-list': time.sleep(0.4)
                if scenario == 'list-error': return self.send(dict(errno=20013))
                if scenario == 'huge': return self.send(b'x' * (9 * 1024 * 1024))
                with lock:
                    directory = q('dir')
                    if directory not in files or not files[directory]['isdir']: return self.send(dict(errno=-9))
                    entries = sorted([v for p, v in files.items() if p.rsplit('/', 1)[0] == directory], key=lambda v: v['path'])
                    start, limit = int(q('start', '0')), int(q('limit', '1000'))
                    if scenario == 'duplicate-page' and start: start = 0
                    items = [meta(v, self.server.server_port) for v in entries[start:start + limit]]
                    if scenario == 'outside-list' and items: items[0]['path'] = root + '-outside/leak'
                    if scenario == 'duplicate-list' and len(items) > 1: items[1] = items[0]
                    if scenario == 'partial' and items: items[0]['unlist'] = 1
                    result = dict(errno=0, list=items)
                    if scenario == 'nested-list': result = dict(errno=0, data=result)
                    return self.send(result)
            if method == 'precreate':
                blocks = json.loads(f('block_list')); size = int(f('size')); target = f('path')
                with lock:
                    if target in files and f('rtype') == '0': return self.send(dict(errno=-8))
                    uploadid = 'task-' + str(len(uploads))
                    uploads[uploadid] = dict(path=target, size=size, blocks=blocks, parts={})
                if scenario == 'bad-blocks': return self.send(dict(errno=0, path=target, uploadid=uploadid, return_type=1, block_list=[999]))
                indices = list(range(len(blocks)))
                if scenario == 'empty-blocks': indices = []
                return self.send(dict(errno=0, path=target, uploadid=uploadid, return_type=1, block_list=indices))
            if method == 'locateupload':
                url = 'http://127.0.0.1:%d' % self.server.server_port
                if scenario == 'evil-upload-host': url = 'https://evil.example'
                return self.send(dict(error_code=0, servers=[dict(server=url)]))
            if method == 'upload':
                message = BytesParser(policy=default).parsebytes(('Content-Type: ' + self.headers['Content-Type'] + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + raw)
                part = next(p for p in message.iter_parts() if p.get_param('name', header='content-disposition') == 'file')
                data = part.get_payload(decode=True); digest = hashlib.md5(data).hexdigest()
                with lock:
                    upload = uploads[q('uploadid')]; index = int(q('partseq'))
                    if digest != upload['blocks'][index] or q('path') != upload['path']: return self.send(dict(errno=31363))
                    upload['parts'][index] = data
                if scenario == 'slow-upload': time.sleep(0.4)
                return self.send(dict(md5='0' * 32 if scenario == 'bad-md5' else digest))
            if method == 'create':
                with lock:
                    target = f('path')
                    if target in files and f('rtype', '0') == '0': return self.send(dict(errno=-8))
                    if target.rsplit('/', 1)[0] not in files: return self.send(dict(errno=-9))
                    if f('isdir') == '1': return self.send(dict(errno=0, **meta(put(target, True), self.server.server_port)))
                    upload = uploads[f('uploadid')]; blocks = json.loads(f('block_list'))
                    if blocks != upload['blocks'] or len(upload['parts']) != len(blocks): return self.send(dict(errno=31363))
                    data = b''.join(upload['parts'][i] for i in range(len(blocks)))
                    if len(data) != upload['size'] or target != upload['path']: return self.send(dict(errno=2))
                    item = put(target, data=data)
                    return self.send(dict(errno=0, **meta(item, self.server.server_port)))
            if method == 'filemanager':
                opera = q('opera'); entries = json.loads(f('filelist')); record = entries[0]
                source = record if isinstance(record, str) else record['path']
                if scenario == 'async-result': return self.send(dict(errno=0, info=[], taskid=123))
                if scenario == 'entry-error': return self.send(dict(errno=0, info=[dict(errno=-7, path=source)]))
                with lock:
                    if source not in files: return self.send(dict(errno=-9))
                    if opera != 'delete':
                        target = record['dest'] + '/' + record['newname']
                        if target in files: return self.send(dict(errno=-8))
                        for original in list(files):
                            if original == source or original.startswith(source + '/'):
                                item = files[original]; destination = target + original[len(source):]
                                put(destination, bool(item['isdir']), item['data'])
                    if opera in ('move', 'delete'):
                        for original in list(files):
                            if original == source or original.startswith(source + '/'): del files[original]
                    return self.send(dict(errno=0, info=[dict(errno=0, path=source)]))
            self.send(dict(errno=2), status=400)
        except (BrokenPipeError, ConnectionResetError): pass

    def download(self, path):
        fsid = int(path.rsplit('/', 1)[1])
        with lock: item = next(v for v in files.values() if v['fs_id'] == fsid); data = item['data']
        if scenario == 'error-download': return self.send(dict(errno=31360, request_id=1))
        if scenario == 'changed-download':
            with lock: item['server_mtime'] += 1
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data) + (10 if scenario == 'short-download' else 0)))
        self.send_header('Connection', 'close'); self.close_connection = True
        self.end_headers()
        if scenario == 'slow-download': time.sleep(0.4)
        self.wfile.write(data)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(workspace, 'port'), 'w') as output: output.write(str(server.server_port))
server.serve_forever()
