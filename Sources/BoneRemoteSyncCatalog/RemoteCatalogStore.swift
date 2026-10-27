import Foundation

/// Offline persistence boundary. Mutations use expected revisions to reject stale writers.
public protocol RemoteCatalogStore: Sendable {
    func saveProfile(_ profile: RemoteSourceProfile, expectedRevision: Int64?) async throws
    func profile(id: UUID) async throws -> RemoteSourceProfile
    func profiles() async throws -> [RemoteSourceProfile]
    func saveRoot(_ root: RemoteCatalogRoot, expectedRevision: Int64?) async throws
    func root(id: UUID) async throws -> RemoteCatalogRoot
    func roots(sourceID: UUID) async throws -> [RemoteCatalogRoot]
    func listCached(rootID: UUID, directory: String, query: RemoteCatalogQuery) async throws -> RemoteCatalogSnapshot
    func clearIndex(rootID: UUID) async throws
    func removeProfile(id: UUID) async throws
}
