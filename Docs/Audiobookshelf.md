# Audiobookshelf

`BoneRemoteSyncAudiobookshelf` provides a native Swift actor for Audiobookshelf libraries, books, podcasts, concrete media files, listening progress and direct playback sessions. It uses the shared bounded Content transport and conforms to `RemoteSource` for registered file downloads. It requires Swift 6 and supports macOS 12, iOS 15, tvOS 15 and visionOS 1.

The protocol baseline is official **v2.37.2**, commit **edb1f7efc92ecacdef51aafb4d9d5054ce10604f**. The tests use a synthetic Python HTTP server on `127.0.0.1`; no real Audiobookshelf deployment or credentials were supplied. Passing fixtures proves the documented wire contract and lifecycle behavior, not acceptance against a deployed server.

The adapter is available in pushed development commit `fe8cfc2`, but is not part of the `v0.8.2` release tag. See the [version matrix](../README.md#开发源码与版本范围). Import the Kit product for the unified API, or select the individual products used by the host. For shared browser screens, see [RemoteBrowser](Browser.md); native progress and playback methods remain separate.

The snippets below run inside host-owned async code. Supply the saved credential/user ID, selected library/item/episode/file IDs, a private cache directory and the media-consumer callback. Keep the source connected while using it; stop playback and shut down Transfer before disconnecting it on both success and failure. These snippets do not constitute a standalone player.

## Connect and verify the account

```swift
import Foundation
import BoneRemoteSyncKit

let source = AudiobookshelfSource(configuration: try .init(
    baseURL: URL(string: "https://books.example.org/abs/")!,
    maxConcurrentRequests: 3,
    maxResponseBytes: 8 * 1024 * 1024,
    maxDownloadReferences: 256
))
try await source.connect(.apiToken(tokenFromKeychain), expectedUserID: savedUserID)
let user = try await source.currentUser()
let binding = try await source.sourceBinding()
```

The base URL is the canonical service root, including the reverse proxy mount. `https://host/abs/` produces `https://host/abs/api/...` and `https://host/abs/login`. Redirects are rejected. HTTPS is the default; opt into `allowsInsecureHTTP: true` only when the host intentionally uses HTTP. Authentication is verified by `GET /api/me` before the source becomes connected. `expectedUserID` prevents silently reconnecting to another account; use the returned user ID after a first connection to establish that expectation.

`connect(.basic(username:password:))` sends the Audiobookshelf local login JSON body to `POST /login`, with `X-Return-Tokens: true`. This credential case describes account/password login; it does not send HTTP Basic auth. The returned `user.accessToken` becomes the Bearer credential. The legacy `user.token` field is never used or exposed in the public user model. `connect(.apiToken(...))` sends a static API token as `Authorization: Bearer …`.

After a local login, `authenticationTokens()` explicitly returns `AudiobookshelfTokens` with the access token and optional refresh token. This sensitive type is not Codable and both its textual descriptions are redacted. Store secrets only in protected host storage. Static-token connections return nil from this method.

This adapter does **not** rotate refresh tokens or silently retry requests. The host may explicitly obtain renewed tokens and call `connect(tokens:expectedUserID:)`, or perform a new local login. The shared transport contract does not expose the `X-Refresh-Token` header required by v2.37.2's `/auth/refresh`; the adapter does not substitute an incorrect body/header protocol. `connect(tokens:)` consumes only the supplied access token and does not retain the supplied refresh token. All reconnects create a new binding and invalidate old file references and playback sessions. Recreate the Transfer materializer after reconnecting.

## Browse and search

```swift
let libraries = try await source.libraries()
let page = try await source.items(libraryID: libraryID, page: 0, pageSize: 50)
let matches = try await source.search(libraryID: libraryID, query: "Le Guin", limit: 25)
let book = try await source.item(id: itemID)
let episode = try await source.episode(itemID: podcastID, episodeID: episodeID)
let imageData = try await source.cover(itemID: itemID, width: 400)
```

Pages are zero based, with size `1...500`. `ContentPage` returns the server total and `hasNextPage`; the host requests subsequent pages explicitly. ABS echoes `page` and `limit` as strings in this version; both numeric and string encodings are accepted and validated. Inconsistent pages, duplicate identities and mismatched library relationships fail rather than becoming an empty page.

Library search is a native `q`/`limit` request. ABS returns separate categories; `AudiobookshelfSearchResults.books` and `.podcasts` expose item matches. The limit applies per category, and ABS does not provide a public search cursor or total. This adapter does not expose the author, narrator, tag, series or episode-match search facets. Fetch podcast details to browse its episodes.

Expanded item details preserve book authors, narrators, series, chapters, files and tracks, or podcast metadata and episodes. Audio file `index == -1` means the file is excluded from playback; it remains available as file metadata while the server's `tracks` determines the playback sequence. A listing may omit details, so its file/track/episode arrays remain nil. An expanded podcast response contains its episodes in one response; `maxResponseBytes` bounds it and the adapter does not fetch an unbounded episode collection. Server absolute paths, folder paths, raw cover paths and enclosure URLs are excluded. Missing sizes and timestamps stay nil. ABS timestamps are milliseconds since the Unix epoch.

## Download a selected file through Transfer

```swift
import BoneRemoteSyncTransfer

let details = try await source.item(id: itemID)
// Present details.files or details.audioFiles and use the selected concrete file ID.
let reference = try await source.prepareDownload(itemID: itemID, fileID: selectedFileID)
let materializer = RemoteFileMaterializer(
    source: source,
    sourceBinding: try await source.sourceBinding(),
    cacheDirectory: privateCacheDirectory
)
do {
    let lease = try await materializer.materialize(reference)
    try await lease.withAccess { localURL in
        try await hostOpenLocalMedia(localURL)
    }
    await materializer.shutdown()
} catch {
    await materializer.shutdown()
    throw error
}
```

`prepareTrackDownload(itemID:trackIndex:episodeID:)` selects a track by the server's index and resolves its concrete file; a podcast requires its episode ID. `prepareDownload(itemID:fileID:)` selects one actual library/audio/episode file after re-fetching details. The server's download permission is checked, and bytes come from `/api/items/{itemID}/file/{fileID}/download`. A multi-file book is never represented as a fictitious single download.

The registered reference and exact `RemoteEntry` are required for `stat`/`download`. Forged, changed or prior-connection entries fail. The registry is bounded by `maxDownloadReferences`; reconnect clears it. Full downloads validate known byte sizes, install atomically, and preserve an existing destination on cancellation or failure. Resume and expected-ETag options are unsupported. The adapter does not invent ETags or modification dates. File transfer never writes listening progress.

`RemoteSource.capabilities` advertises `list: false`, `stat: true`, `download: true`; file upload, deletion, move, directory traversal and filesystem catalog synthesis are unavailable. Use typed library/item APIs for browsing.

## Explicit progress

```swift
let before = try await source.mediaProgress(itemID: itemID, episodeID: nil)
try await source.updateMediaProgress(
    itemID: itemID,
    update: .init(currentTime: 120, duration: 3600, progress: 120.0 / 3600.0)
)
```

`mediaProgress` returns nil for the server's 404 response. It validates the returned user, item and episode. Updates are sparse PATCH bodies: omitted fields remain omitted. Available fields are `currentTime`, `duration`, `progress`, `isFinished`, `hideFromContinueListening`, `ebookLocation` and `ebookProgress`. Fractions must be `0...1`; numeric values must be finite and nonnegative. Empty updates are rejected. Both book and episode endpoints are supported.

ABS applies `isFinished` using its own semantics: clearing an already finished item may reset its playhead. Do not assume that combining `isFinished: false` and a playhead update is equivalent to a single seek. Fetch progress after a write when the host needs the authoritative state. Network errors may occur after a mutation commits; the SDK does not replay the write.

## Direct playback for a host player

```swift
let session = try await source.createPlaybackSession(
    itemID: itemID,
    episodeID: nil,
    supportedMimeTypes: ["audio/mpeg", "audio/mp4"]
)
for track in session.tracks {
    let request = track.request.urlRequest()
    // Pass request to the host's authenticated media loader.
    // track.track.startOffset and duration map the overall playhead to this file.
}
try await source.syncPlaybackSession(session, update: .init(
    currentTime: 150, timeListened: 30, duration: session.duration
))
try await source.closePlaybackSession(session, update: .init(
    currentTime: 155, timeListened: 5, duration: session.duration
))
```

The host supplies its supported MIME types. The adapter verifies available tracks before sending `forceDirectPlay: true` and `forceTranscode: false`, requires returned `playMethod == 0`, and accepts only same-service concrete item file URLs. HLS, transcoding, foreign origins, unrelated item paths and unexpected track lists fail. Each `AudiobookshelfPlaybackTrack` contains a `ContentStreamRequest` carrying the authenticated request. These requests intentionally contain credentials; never log/persist them or forward authentication through redirects. Existing requests held by the host cannot be revoked locally on disconnect: the host must stop its loader/player and discard them when reconnecting.

This module does not implement AVPlayer, decoding, playback controls, range scheduling, seeking, queue transitions, background audio or DRM. A MIME match is not a codec compatibility guarantee; the host must verify its actual player capabilities. For track `startOffset = 300`, the absolute item time `330` corresponds to local track time `30`.

`timeListened` is the incremental listening duration since the last sync, independent of seek position. It is bounded to one day per update. The host controls when to sync and close. The source supports one active session for its generated device identity; starting another invalidates the previous handle, as ABS closes prior sessions for that device. Session operations are serialized and overlapping calls fail with `rateLimited`. Closed, replaced, cross-source or prior-generation handles are rejected. A submitted close or replacement create invalidates the previous local handle even when the server outcome is unknown, preventing accidental replay. A local concurrency rejection or cancellation/timeout while still waiting for admission preserves the handle, because no request was started.

`disconnect()` cancels requests and invalidates local state without a server-side write. Call `closePlaybackSession` explicitly first when session accounting is needed. If a create response is malformed/lost, the server may still have created a session; the adapter never trusts unvalidated session identifiers to perform hidden cleanup. A subsequent explicit create for the same device lets ABS replace that session.

## Bounds and verification

The shared transport limits simultaneous requests (`1...8`), inter-request admission rate, response bytes, timeout and registered downloads. Oversubscription reports `RemoteSyncError.rateLimited`. Libraries, files, tracks, episodes and chapters also have a 10,000-element ceiling; public pages cap at 500. Response and file transfer cancellation waits for transport cleanup before the operation finishes. Provider generation checks prevent late responses from publishing into a newer connection, and downloads reserve their destination until old operations finish.

The macOS Swift Testing suite uses only Python's standard library and an ephemeral loopback port. It checks modern login/header shape, static Bearer auth, account guards, reverse-proxy mount preservation, string pagination, books/podcasts/search/cover, per-file Transfer materialization, forged/stale references, explicit progress, direct playback/sync/close, rejected foreign/HLS/transcoded sessions, cancellation and reconnect races. Run:

```sh
swift test --filter AudiobookshelfTests
```

`BONE_PYTHON` can point to a Python 3 executable. Tests explicitly skip when Python is unavailable. Real deployment acceptance, player codec support and TLS/reverse proxy configuration remain host integration checks.

## Official evidence

All source links below pin the same v2.37.2 commit. The [API documentation](https://api.audiobookshelf.org/) is useful context; implementation details were checked against pinned server source.

- [Auth.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/Auth.js#L294-L358): local login, `X-Return-Tokens`, modern token fields, and `X-Refresh-Token` refresh protocol.
- [ApiRouter.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/routers/ApiRouter.js): library/item/file/episode/progress/session routes.
- [LibraryController.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/LibraryController.js#L604-L638): `results`, `total`, string query pagination; search at lines 959–968.
- [MeController.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/MeController.js): current user, progress 404, sparse PATCH and plain status response.
- [User.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/User.js#L603-L637): browser user/permissions shape; raw legacy token intentionally excluded.
- [PlaybackSessionManager.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/managers/PlaybackSessionManager.js#L313-L363): direct-play selection, one session per user/device, tracks; sync/close update semantics below.
- [SessionController.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/controllers/SessionController.js#L158-L181), [PlaybackSession.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/objects/PlaybackSession.js#L86-L115), [AudioTrack.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/objects/files/AudioTrack.js#L26-L35): session payload and concrete track URL construction.
- [Book.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/Book.js), [PodcastEpisode.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/PodcastEpisode.js#L193-L237), [MediaProgress.js](https://github.com/advplyr/audiobookshelf/blob/edb1f7efc92ecacdef51aafb4d9d5054ce10604f/server/models/MediaProgress.js#L155-L175): expanded details, episode association, progress model and millisecond timestamps.
