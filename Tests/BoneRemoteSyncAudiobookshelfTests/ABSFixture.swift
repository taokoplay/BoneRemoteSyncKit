#if os(macOS)
import Foundation
import Darwin
import BoneRemoteSyncTestSupport

/// Every credential and media byte here is synthetic. Never contacts a real deployment.
final class ABSFixture: @unchecked Sendable {
    struct Request: Decodable {
        let method: String
        let path: String
        let authorization: String?
        let returnTokens: String?
        let body: [String: JSONValue]?
    }
    enum JSONValue: Decodable, Equatable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
            else { self = .array(try c.decode([JSONValue].self)) }
        }
    }
    let directory: URL
    private let process = Process()
    private let stopped = DispatchSemaphore(value: 0)
    private(set) var baseURL: URL!
    private init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BoneAudiobookshelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func start(mode: String = "normal") async throws -> ABSFixture {
        let fixture = try ABSFixture()
        let script = fixture.directory.appendingPathComponent("server.py")
        try python.write(to: script, atomically: true, encoding: .utf8)
        fixture.process.executableURL = try PythonFixture.executableURL()
        fixture.process.arguments = [script.path, fixture.directory.path, mode]
        fixture.process.standardOutput = FileHandle.nullDevice
        fixture.process.standardError = FileHandle.nullDevice
        let stopped = fixture.stopped
        fixture.process.terminationHandler = { _ in stopped.signal() }
        try fixture.process.run()
        let ready = fixture.directory.appendingPathComponent("port")
        for _ in 0..<250 {
            if let text = try? String(contentsOf: ready, encoding: .utf8), let port = Int(text) {
                fixture.baseURL = URL(string: "http://127.0.0.1:\(port)/abs/")!
                return fixture
            }
            if !fixture.process.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        fixture.stop()
        throw FixtureError.startup
    }
    func stop() {
        if process.isRunning {
            process.terminate()
            if stopped.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = stopped.wait(timeout: .now() + 2)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }
    func requests() throws -> [Request] {
        let data = try Data(contentsOf: directory.appendingPathComponent("requests.jsonl"))
        return try data.split(separator: 10).map { try JSONDecoder().decode(Request.self, from: Data($0)) }
    }
    func waitForRequest(containing path: String) async throws {
        for _ in 0..<250 {
            if (try? requests().contains(where: { $0.path.contains(path) })) == true { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw FixtureError.requestTimeout
    }
    enum FixtureError: Error { case startup, requestTimeout }

    private static let python = #"""
import base64, copy, http.server, json, pathlib, sys, threading, time, urllib.parse
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
log_lock = threading.Lock()
progress = {}
sessions = {}
serial = 0
AUDIO = b'ID3fixture-audio'
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=')

def user():
    return {'id':'user-1','username':'fixture-reader','type':'user','isActive':True,
            'token':'legacy-token-must-not-surface','librariesAccessible':['lib-books','lib-podcasts'],
            'permissions':{'download':mode != 'no-download','update':False,'upload':False,'delete':False,
                           'accessAllLibraries':False,'accessExplicitContent':True}}

def audio(ino, index=1):
    return {'ino':ino,'index':index,'duration':30.0,'mimeType':'audio/mpeg',
            'metadata':{'filename':str(ino)+'.mp3','size':len(AUDIO),'path':'/srv/private/audio.mp3','relPath':'audio.mp3'}}

def track(item, ino, index=1):
    return {'index':index,'startOffset':(index-1)*30.0,'duration':30.0,'title':str(ino)+'.mp3',
            'contentUrl':'/api/items/'+item+'/file/'+str(ino),'mimeType':'audio/mpeg','codec':'mp3',
            'metadata':{'path':'/srv/private/audio.mp3'}}

def item(i='book-1', mini=False):
    podcast = i == 'podcast-1'
    result = {'id':i,'libraryId':'lib-podcasts' if podcast else 'lib-books',
              'mediaType':'podcast' if podcast else 'book','path':'/srv/private',
              'media':{'id':'media-podcast' if podcast else 'media-book',
                       'metadata':{'title':'Fixture Podcast' if podcast else 'Fixture Book','description':'An example',
                                   'author':'Podcast Host'} if podcast else
                                  {'title':'Fixture Book','authors':[{'id':'author-1','name':'A. Writer'}],
                                   'narrators':['A. Reader'],'series':[{'id':'series-1','name':'Sample','sequence':'1'}]},
                       'tags':['fixture'],'duration':30 if podcast else 60,'size':len(AUDIO)*(1 if podcast else 2)}}
    if not mini:
        result['libraryFiles'] = [audio('201')] if podcast else [audio(101), audio('102',2)]
        if podcast:
            result['media']['episodes'] = [{'id':'episode-1','libraryItemId':i,'podcastId':'media-podcast',
                'title':'Episode One','season':'1','episode':'1','description':'Episode notes','duration':30,
                'publishedAt':1700000000000,'audioFile':audio('201'),'audioTrack':track(i,'201'),'chapters':[]}]
        else:
            result['media'].update({'audioFiles':[audio(101),audio('102',2)],
                                   'tracks':[track(i,'101'),track(i,'102',2)],
                                   'chapters':[{'id':0,'start':0,'end':60,'title':'Chapter One'}]})
            if mode == 'excluded-audio':
                result['media']['audioFiles'].append(audio('103', -1))
                result['libraryFiles'].append(audio('103', -1))
    return result

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, status, value=b'', mime='application/json'):
        if not isinstance(value, bytes): value=json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type',mime)
        self.send_header('Content-Length',str(len(value)))
        self.end_headers()
        try: self.wfile.write(value)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self): self.handle_request()
    def do_POST(self): self.handle_request()
    def do_PATCH(self): self.handle_request()
    def handle_request(self):
        global serial
        raw = self.rfile.read(int(self.headers.get('Content-Length','0')))
        body = json.loads(raw) if raw else None
        with log_lock:
            with (root/'requests.jsonl').open('a') as f:
                f.write(json.dumps({'method':self.command,'path':self.path,
                    'authorization':self.headers.get('Authorization'),
                    'returnTokens':self.headers.get('X-Return-Tokens'),'body':body})+'\n')
        parsed = urllib.parse.urlsplit(self.path)
        if not parsed.path.startswith('/abs/'): return self.respond(404)
        path = parsed.path[len('/abs'):]
        query = urllib.parse.parse_qs(parsed.query)
        if path == '/login':
            if body.get('username') == 'slow-reader': time.sleep(1)
            if self.headers.get('X-Return-Tokens') != 'true' or body.get('password') != 'fixture-password':
                return self.respond(401, {'error':'bad login'})
            identity = 'other-user' if mode == 'login-identity' else 'user-1'
            return self.respond(200, {'user':{'id':identity,'accessToken':'fixture-access','refreshToken':'fixture-refresh'}})
        if self.headers.get('Authorization') not in ['Bearer fixture-access','Bearer fixture-api']:
            return self.respond(401, {'error':'bad token'})
        if path == '/api/me': return self.respond(200,user())
        if path == '/api/libraries':
            if mode == 'unauthorized': return self.respond(401,{'error':'expired'})
            if mode == 'malformed': return self.respond(200,{'wrong':[]})
            return self.respond(200,{'libraries':[{'id':'lib-books','name':'Books','mediaType':'book','displayOrder':1},
                                                {'id':'lib-podcasts','name':'Podcasts','mediaType':'podcast'}]})
        if path.endswith('/items') and path.startswith('/api/libraries/'):
            page, limit = int(query['page'][0]), int(query['limit'][0])
            values = [item('book-1',True),item('book-2',True)]
            result={'results':values[page*limit:(page+1)*limit],'page':str(page),'limit':str(limit),'total':2}
            if mode == 'bad-page': result['page']='99'
            return self.respond(200,result)
        if path.endswith('/search'):
            if query.get('q') != ['Fixture & chapter']: return self.respond(400)
            if mode == 'bad-search': return self.respond(200,{})
            podcast = 'lib-podcasts' in path
            return self.respond(200,{'podcast' if podcast else 'book':[{'libraryItem':item('podcast-1' if podcast else 'book-1')}],
                                    'tags':[],'authors':[],'series':[]})
        if path.startswith('/api/me/progress/'):
            key=path[len('/api/me/progress/'):]
            if self.command == 'PATCH':
                parts=key.split('/')
                value=progress.setdefault(key,{'id':'progress-1','userId':'user-1','libraryItemId':parts[0],
                    'episodeId':parts[1] if len(parts)>1 else None,'duration':60,'progress':0,
                    'currentTime':0,'isFinished':False,'lastUpdate':1700000000000})
                value.update(body)
                return self.respond(200,b'OK','text/plain; charset=utf-8')
            if key not in progress: return self.respond(404,b'Not Found','text/plain')
            value=copy.deepcopy(progress[key])
            if mode == 'bad-progress': value['userId']='other-user'
            return self.respond(200,value)
        if path.startswith('/api/items/'):
            parts=path.split('/')
            i=parts[3]
            if len(parts)==4:
                if i=='slow': time.sleep(1)
                if query.get('expanded') != ['1']: return self.respond(400)
                value=item(i)
                if mode == 'bad-item': value['id']='wrong-item'
                if mode == 'bad-track-index': value['media']['tracks'][1]['index']=1
                return self.respond(200,value)
            if parts[4]=='cover': return self.respond(200,PNG,'image/png')
            if parts[4]=='file':
                if i=='slow-download': time.sleep(1)
                return self.respond(200,AUDIO,'audio/mpeg')
            if parts[4]=='play' and self.command=='POST':
                if body.get('forceDirectPlay') is not True or body.get('forceTranscode') is not False:
                    return self.respond(400)
                serial+=1
                sid='session-'+str(serial)
                episode=parts[5] if len(parts)>5 else None
                tracks=[track(i,'201')] if episode else [track(i,'101'),track(i,'102',2)]
                result={'id':sid,'userId':'user-1','libraryId':'lib-podcasts' if episode else 'lib-books',
                        'libraryItemId':i,'episodeId':episode,'playMethod':0,'duration':30 if episode else 60,
                        'currentTime':0,'chapters':[],'audioTracks':tracks}
                if mode == 'transcode': result['playMethod']=2
                if mode == 'foreign-track': tracks[0]['contentUrl']='https://evil.invalid/audio.mp3'
                if mode == 'hls': tracks[0]['mimeType']='application/vnd.apple.mpegurl'
                if mode == 'session-identity': result['userId']='other-user'
                sessions[sid]=result
                return self.respond(200,result)
        if path.startswith('/api/session/'):
            sid=path.split('/')[3]
            if sid not in sessions: return self.respond(404)
            if path.endswith('/close'): del sessions[sid]
            if path.endswith('/close') and mode == 'close-error': return self.respond(500, {'error':'unknown close outcome'})
            return self.respond(200,b'OK','text/plain; charset=utf-8')
        return self.respond(404,b'Not Found','text/plain')

server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
server.daemon_threads=True
(root/'port').write_text(str(server.server_port))
server.serve_forever()
"""#
}
#endif
