import Foundation
import BoneRemoteSyncKit

/// 宿主通过 choose 展示页面、搜索/导航，并返回用户明确选定的书目与格式。
/// consume 必须在返回前结束对 URL 的读取；长期收藏应复制到宿主自己的目录。
func importOPDSPublication(
    configuration: OPDSConfiguration,
    credential: RemoteCredential,
    cacheDirectory: URL,
    choose: @Sendable (OPDSSource, OPDSPage) async throws -> (OPDSPublication, OPDSAcquisition),
    consume: @Sendable (URL) async throws -> Void
) async throws {
    let source = OPDSSource(configuration: configuration)
    do {
        try await source.connect(credential)
        let page = try await source.browse()
        let (publication, acquisition) = try await choose(source, page)
        let reference = try await source.prepareDownload(publication, acquisition: acquisition)
        let materializer = RemoteFileMaterializer(
            source: source,
            sourceBinding: try await source.sourceBinding(),
            cacheDirectory: cacheDirectory
        )
        let coordinator = RemoteTransferCoordinator(materializer: materializer, maxConcurrentTransfers: 2)
        do {
            let taskID = await coordinator.submit(.init(reference: reference))
            let lease = try await coordinator.wait(for: taskID)
            try await lease.withAccess { url in try await consume(url) }
            await coordinator.shutdown()
            await materializer.shutdown()
        } catch {
            await coordinator.shutdown()
            await materializer.shutdown()
            throw error
        }
        await source.disconnect()
    } catch {
        await source.disconnect()
        throw error
    }
}

/// UI 可用这些入口逐页浏览；不自动扫描整个书库。
func moreOPDSBooks(source: OPDSSource, page: OPDSPage) async throws -> OPDSPage? {
    guard let next = page.nextCursor else { return nil }
    return try await source.nextPage(next)
}

func searchOPDSBooks(source: OPDSSource, query: String) async throws -> OPDSPage {
    try await source.search(query)
}
