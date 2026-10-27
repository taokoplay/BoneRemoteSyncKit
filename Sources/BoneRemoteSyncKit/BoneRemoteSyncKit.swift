// Unified public entry point. Re-export the original modules so their public types,
// protocol conformances and extensions keep the same identity for existing clients.
// @_exported is a Swift compiler underscored attribute; consumer tests cover this
// deliberate compatibility boundary without duplicating API types or forwarding methods.
@_exported import BoneRemoteSyncCore
@_exported import BoneRemoteSyncLocal
@_exported import BoneRemoteSyncWebDAV
@_exported import BoneRemoteSyncOneDrive

@_exported import BoneRemoteSyncCatalog
