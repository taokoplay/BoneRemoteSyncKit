# Audiobookshelf integration example

Add the `BoneRemoteSyncAudiobookshelf` and `BoneRemoteSyncTransfer` package products to a Swift 6 host target, then copy [AudiobookshelfExample.swift](AudiobookshelfExample.swift). The example is a set of callable integration functions, with no embedded credentials or executable startup that could write progress accidentally.

1. Call `AudiobookshelfExample.connect(baseURL:credential:expectedUserID:)` with the canonical HTTPS service mount and a Keychain credential. `.basic` performs local JSON login; `.apiToken` uses Bearer auth. Save the verified `source.connectedUserID()` for future account checks.
2. Call `source.libraries()`, then `AudiobookshelfExample.browse` with the chosen library ID. Request each next zero-based page explicitly. `source.search` runs a bounded native library search.
3. Fetch `source.item(id:)` or `source.episode(itemID:episodeID:)`. Choose one concrete file ID for `withDownloadedFile`. Its closure owns access to the materialized local file until it returns; the helper releases the lease and shuts down its materializer on success or failure.
4. For streaming, call `beginPlayback` with the host player's supported MIME types. Give each `session.tracks[n].request.urlRequest()` to the host's authenticated media loader, preserving the server's track order and `startOffset`. Reject redirects in that loader and discard the requests when the source reconnects.
5. Use `reportPlayback` on actual host playback events and `endPlayback` on explicit stop. `absoluteItemTime` is the book/episode playhead; `listenedSinceLastSync` counts elapsed listening time since the preceding sync. The example does not invent playback timing or provide a player.
6. Stop host playback, explicitly close any session whose accounting matters, then call `source.disconnect()`.

Explicit progress editing is also available independently of a playback session:

```swift
let saved = try await source.mediaProgress(itemID: selectedItemID)
try await source.updateMediaProgress(itemID: selectedItemID, update: .init(isFinished: true))
```

Keep token/stream request values out of logs and persistent content models. Reconnect invalidates references and session handles; token rotation itself belongs to the host, and writes are never automatically replayed. Direct file playback only is supported: no HLS, transcoding, AVPlayer implementation, background audio, or full-library fetch-all operation.

The [provider guide](../../Docs/Audiobookshelf.md) records the exact v2.37.2 source baseline, bounds, API semantics and limitations. Formal tests run against a synthetic loopback fixture; this example has no claim of acceptance against an unspecified real deployment.
