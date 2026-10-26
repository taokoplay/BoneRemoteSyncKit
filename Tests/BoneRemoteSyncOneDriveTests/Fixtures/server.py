import sys, json, time, threading, urllib.parse, hashlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
log, scenario = sys.argv[1:3]
lock = threading.Lock()
PAYLOAD = b''.join(hashlib.sha256(str(i).encode()).digest() for i in range(32768))
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def record(self, body=''):
        with lock, open(log,'a') as f:
            f.write(json.dumps(dict(method=self.command,path=self.path,authorization=self.headers.get('Authorization'),cookie=self.headers.get('Cookie'),body=body))+'\n')
    def reply(self,status,value,headers=None):
        data = value if isinstance(value,bytes) else json.dumps(value).encode()
        self.send_response(status)
        for key,val in (headers or {}).items(): self.send_header(key,val)
        self.send_header('Content-Length',len(data)); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError): pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0))).decode(); self.record(body)
        args=urllib.parse.parse_qs(body)
        if scenario=='token-error': return self.reply(400,dict(error='invalid_grant',error_description='SECRET-TOKEN-IN-ERROR'))
        if scenario=='token-large': return self.reply(200,b'x'*(1024*1024+1))
        if scenario=='token-redirect': return self.reply(302,b'',{'Location':self.base+'/stolen'})
        if scenario=='refresh-slow': time.sleep(.3)
        if scenario=='bad-token': return self.reply(200,dict(access_token='NEW',expires_in=-1,token_type='Bearer'))
        self.reply(200,dict(access_token='NEW',refresh_token='ROTATED',expires_in=3600,token_type='Bearer',scope='Files.Read'))
    @property
    def base(self): return 'http://127.0.0.1:'+str(self.server.server_port)
    def item(self,id='file',name='资料 #?%.bin',size=len(PAYLOAD),folder=False):
        value=dict(id=id,name=name,size=size,eTag='"v1"',lastModifiedDateTime='2026-10-20T00:00:00Z',createdDateTime='2026-10-19T01:02:03Z',parentReference=dict(driveId='D'))
        value['folder' if folder else 'file']={} if folder else dict(mimeType='application/octet-stream')
        if not folder: value['@microsoft.graph.downloadUrl']=self.base+'/download/'+id
        return value
    def do_GET(self):
        self.record(); parsed=urllib.parse.urlsplit(self.path); path=parsed.path
        if path.startswith('/download/'):
            if scenario=='expired-always': return self.reply(403,b'EXPIRED')
            if scenario=='partial': return self.reply(206,PAYLOAD,{'Content-Range':'bytes 0-1048575/1048576'})
            if scenario=='expired' and not hasattr(self.server,'expired'):
                self.server.expired=True; return self.reply(403,b'EXPIRED')
            if scenario=='download-redirect': return self.reply(302,b'',{'Location':self.base+'/stolen'})
            if scenario=='short': return self.reply(200,PAYLOAD[:10])
            if scenario=='changes-during-body': self.server.changed=True
            if scenario=='unknown-short':
                self.send_response(200); self.send_header('Connection','close'); self.end_headers(); self.wfile.write(PAYLOAD[:10]); self.close_connection=True; return
            if scenario=='compressed': return self.reply(200,PAYLOAD,{'Content-Encoding':'gzip'})
            data=b'' if path.endswith('/empty') else PAYLOAD
            if scenario in ('slow','cut'):
                self.send_response(200); self.send_header('Content-Length',len(data)); self.end_headers()
                try:
                    for i in range(0,len(data),4096):
                        self.wfile.write(data[i:i+4096]); self.wfile.flush(); time.sleep(.01)
                        if scenario=='cut' and i>65536: self.close_connection=True; return
                except (BrokenPipeError,ConnectionResetError): pass
                return
            return self.reply(200,data)
        if self.headers.get('Authorization')=='Bearer OLD': return self.reply(401,dict(error=dict(code='InvalidAuthenticationToken')))
        if scenario=='always401': return self.reply(401,dict(error=dict(code='InvalidAuthenticationToken')))
        if scenario=='large-json': return self.reply(200,b'x'*(8*1024*1024+1))
        if scenario=='unknown-large-json':
            self.send_response(200); self.send_header('Connection','close'); self.end_headers()
            try: self.wfile.write(b'x'*(8*1024*1024+1))
            except (BrokenPipeError,ConnectionResetError): pass
            self.close_connection=True; return
        if scenario=='error': return self.reply(429,dict(error=dict(message='SECRET-TOKEN-IN-ERROR')),{'Retry-After':'7'})
        if scenario=='graph-redirect': return self.reply(302,b'',{'Location':self.base+'/stolen'})
        if path=='/v1.0/me/drive':
            if scenario=='connect-slow': time.sleep(.4)
            return self.reply(200,dict(id='D',driveType='business' if scenario=='business' else 'personal'))
        if path.endswith('/children'):
            if scenario=='walk' and '/items/folder/' in path: return self.reply(200,dict(value=[]))
            if 'skiptoken=cycle' in parsed.query: return self.reply(200,dict(value=[], **{'@odata.nextLink':self.base+path+'?skiptoken=cycle'}))
            if 'skiptoken=page3' in parsed.query: return self.reply(200,dict(value=[self.item('last','last.txt')]))
            if 'skiptoken=page2' in parsed.query:
                value=dict(value=[self.item('middle','middle.txt')])
                if scenario=='three-pages': value['@odata.nextLink']=self.base+path+'?skiptoken=page3'
                return self.reply(200,value if scenario=='three-pages' else dict(value=[self.item('last','last.txt')]))
            nxt=self.base+path+'?skiptoken=page2'
            if scenario=='evil-next': nxt='https://evil.invalid/v1.0/drives/D/items/root/children?x=1'
            if scenario=='other-next': nxt=self.base+'/v1.0/me/drive?skiptoken=page2'
            if scenario=='cycle': nxt=self.base+path+'?skiptoken=cycle'
            value=dict(value=[self.item('folder','子目录',folder=True),self.item(),self.item('hidden','.secret')], **{'@odata.nextLink':nxt})
            if scenario=='bad-name': value['value'][0]['name']='..'
            if scenario=='duplicate': value['value'].append(value['value'][0])
            if scenario=='remote': value['value'].append(dict(id='remote',name='shared',remoteItem=dict(id='foreign')))
            return self.reply(200,value)
        if path.endswith('/root') or '/root:/' in path or '/items/' in path:
            if 'missing' in path: return self.reply(404,dict(error=dict(code='itemNotFound')))
            folder=path.endswith('/root') or path.endswith('/folder') or '子目录' in urllib.parse.unquote(path)
            item=self.item('root' if path.endswith('/root') else ('folder' if folder else ('empty' if 'empty' in path else 'file')),folder=folder,size=0 if 'empty' in path else len(PAYLOAD))
            if scenario=='unsafe-url': item['@microsoft.graph.downloadUrl']='http://evil.invalid/leak?secret=xxx'
            if scenario=='changed' or getattr(self.server,'changed',False): item['eTag']='"v2"'
            return self.reply(200,item)
        return self.reply(404,dict(error=dict(code='itemNotFound')))
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(server.server_port,flush=True); server.serve_forever()
