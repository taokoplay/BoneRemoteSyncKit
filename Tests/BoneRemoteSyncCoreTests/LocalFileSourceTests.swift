import XCTest
import BoneRemoteSyncCore
import BoneRemoteSyncLocal

final class LocalFileSourceTests: XCTestCase {
    private var root: URL!
    private var source: LocalFileSource!

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BoneRemoteSyncKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sub"),
            withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("nested".utf8).write(to: root.appendingPathComponent("Sub/b.txt"))
        source = LocalFileSource(root: root)
        try await source.connect(.anonymous)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListRootSortsDirectoriesFirst() async throws {
        let page = try await source.list(path: "/")
        XCTAssertEqual(page.entries.map(\.name), ["Sub", "a.txt"])
        XCTAssertTrue(page.entries[0].isDirectory)
        XCTAssertNil(page.nextCursor)
    }

    func testStatAndETag() async throws {
        let entry = try await source.stat(path: "/a.txt")
        XCTAssertEqual(entry.size, 5)
        XCTAssertEqual(entry.type, .file)
        XCTAssertNotNil(entry.etag)
        XCTAssertEqual(entry.path, "/a.txt")
        XCTAssertEqual(entry.id, "a.txt")
    }

    func testStatMissingThrowsNotFound() async {
        do {
            _ = try await source.stat(path: "/nope.txt")
            XCTFail("应当抛 notFound")
        } catch let error as RemoteSyncError {
            guard case .notFound = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testErrorsUseNormalizedPathAndUnsupportedForListingFile() async throws {
        do {
            _ = try await source.stat(path: "a//missing.txt/")
            XCTFail("应当抛 notFound")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .notFound(path: "/a/missing.txt"))
        }

        do {
            _ = try await source.list(path: "a.txt/./")
            XCTFail("文件不能列目录")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .unsupported(operation: "列出非目录条目"))
        }
    }

    func testListRejectsInvalidLimitAndCursorBeforeReading() async throws {
        do {
            _ = try await source.list(path: "/", request: .init(limit: 0))
            XCTFail("非法分页大小应当被拒绝")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .unsupported(operation: "分页大小必须大于0"))
        }
        do {
            _ = try await source.list(path: "/", request: .init(cursor: "unexpected"))
            XCTFail("本地来源不应静默忽略游标")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .unsupported(operation: "本地来源不支持游标分页"))
        }
    }

    func testDownloadWritesFileAndLeavesNoPart() async throws {
        let destination = root.appendingPathComponent("out.txt")
        let entry = try await source.download(path: "/a.txt", to: destination)
        XCTAssertEqual(entry.size, 5)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathExtension("part").path)
        )
    }

    func testDownloadResumesFromOffset() async throws {
        let destination = root.appendingPathComponent("resume.txt")
        let part = destination.appendingPathExtension("part")
        try Data("he".utf8).write(to: part)

        let entry = try await source.stat(path: "/a.txt")
        _ = try await source.download(
            entry,
            to: destination,
            options: RemoteDownloadOptions(resumeFrom: 2, expectedETag: entry.etag)
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hello")
    }

    func testResumeWithStaleETagThrowsConflict() async throws {
        let destination = root.appendingPathComponent("conflict.txt")
        try Data("he".utf8).write(to: destination.appendingPathExtension("part"))

        let entry = try await source.stat(path: "/a.txt")
        do {
            _ = try await source.download(
                entry,
                to: destination,
                options: RemoteDownloadOptions(resumeFrom: 2, expectedETag: "stale")
            )
            XCTFail("应当抛 conflict")
        } catch let error as RemoteSyncError {
            guard case .conflict = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        }
    }

    func testTraversalIsBlocked() async {
        do {
            _ = try await source.stat(path: "/../../etc/passwd")
            // ".." 被归一化到根内，最终查询 /etc/passwd，应当不存在而不是越界读取。
            XCTFail("应当抛 notFound")
        } catch let error as RemoteSyncError {
            guard case .notFound = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }

    func testWalkReturnsAllEntries() async throws {
        var names: [String] = []
        for try await entry in source.walk(path: "/") {
            names.append(entry.name)
        }
        XCTAssertEqual(Set(names), ["Sub", "a.txt", "b.txt"])
    }

    func testListBeforeConnectThrowsNotConnected() async {
        let fresh = LocalFileSource(root: root)
        do {
            _ = try await fresh.list(path: "/")
            XCTFail("应当抛 notConnected")
        } catch let error as RemoteSyncError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("错误类型不符：\(error)")
        }
    }
}
