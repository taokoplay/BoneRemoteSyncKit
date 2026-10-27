import XCTest
import BoneRemoteSyncCore
@testable import BoneRemoteSyncICloud

final class ICloudDriveSourceTests: XCTestCase {
    private var workspace: URL!
    private var root: URL!
    private var source: ICloudDriveSource!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BoneICloud-\(UUID())")
        root = workspace.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello iCloud".utf8).write(to: root.appendingPathComponent("hello.txt"))
        let config = try ICloudDriveConfiguration(directoryPath: "/")
        source = ICloudDriveSource(configuration: config, rootURL: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workspace)
    }

    func testConfigurationRejectsTraversalAndInvalidTimeout() throws {
        XCTAssertThrowsError(try ICloudDriveConfiguration(directoryPath: "/../outside"))
        XCTAssertThrowsError(try ICloudDriveConfiguration(downloadTimeout: 0))
        XCTAssertThrowsError(try ICloudDriveConfiguration(containerIdentifier: "bad/name"))
        let config = try ICloudDriveConfiguration(directoryPath: "docs")
        XCTAssertEqual(config.directoryPath, "/docs")
    }

    func testConnectListStatAndStatusUseCoherentSourceRoot() async throws {
        let before = await source.status()
        XCTAssertEqual(before.availability, .available)
        XCTAssertFalse(before.isUbiquitous)
        try await source.connect(.anonymous)
        let page = try await source.list(path: "/")
        XCTAssertEqual(page.entries.map(\.name), ["hello.txt"])
        let entry = try await source.stat(path: "/hello.txt")
        XCTAssertEqual(entry.size, 12)
        XCTAssertEqual(entry.id, "hello.txt")
        let itemStatus = await source.status(path: "/hello.txt")
        XCTAssertEqual(itemStatus.availability, .available)
    }

    func testICloudSourceDoesNotAcceptStoredCredentials() async throws {
        await XCTAssertThrowsErrorAsync {
            try await self.source.connect(.basic(username: "u", password: "p"))
        } check: { error in
            XCTAssertEqual(error as? RemoteSyncError, .authenticationFailed(reason: "iCloud Drive 凭据由系统账号管理"))
        }
    }

    func testReadWriteOperationsAreAvailableThroughProtocols() async throws {
        try await source.connect(.anonymous)
        let readWrite: any RemoteCopyingSource = source
        XCTAssertTrue(readWrite.capabilities.copy)
        try await readWrite.makeDirectory(path: "/folder")
        let input = workspace.appendingPathComponent("input.txt")
        try Data("payload".utf8).write(to: input)
        let uploaded = try await readWrite.upload(from: input, to: "/folder/file.txt", options: .init(overwrite: false))
        XCTAssertEqual(uploaded.size, 7)
        try await readWrite.copy(from: "/folder/file.txt", to: "/folder/copy.txt")
        try await readWrite.move(from: "/folder/copy.txt", to: "/folder/moved.txt")
        let output = workspace.appendingPathComponent("output.txt")
        _ = try await readWrite.download(path: "/folder/moved.txt", to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data("payload".utf8))
        try await readWrite.remove(path: "/folder")
        await XCTAssertThrowsErrorAsync { _ = try await readWrite.stat(path: "/folder") } check: { error in
            XCTAssertEqual(error as? RemoteSyncError, .notFound(path: "/folder"))
        }
    }

    func testInvalidRootOperationsAndCursorFailClearly() async throws {
        try await source.connect(.anonymous)
        await XCTAssertThrowsErrorAsync {
            _ = try await self.source.list(path: "/", request: .init(cursor: "cursor"))
        } check: { error in
            XCTAssertEqual(error as? RemoteSyncError, .unsupported(operation: "iCloud Drive 不支持游标分页"))
        }
        await XCTAssertThrowsErrorAsync { try await self.source.remove(path: "/") } check: { error in
            XCTAssertEqual(error as? RemoteSyncError, .unsupported(operation: "iCloud Drive 不能删除来源根目录"))
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @escaping () async throws -> Void,
        check: (Error) -> Void
    ) async {
        do {
            try await expression()
            XCTFail("expected an error")
        } catch {
            check(error)
        }
    }
}
