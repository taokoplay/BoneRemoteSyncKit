import XCTest
@testable import BoneRemoteSyncCore

final class RemotePathTests: XCTestCase {
    func testNormalizeCollapsesSeparatorsAndDots() {
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("/"), "/")
        XCTAssertEqual(RemotePath.normalize("a/b"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/a//b/"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("a\\b"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/a/./b/../c"), "/a/c")
    }

    func testNormalizeCannotEscapeRoot() {
        XCTAssertEqual(RemotePath.normalize("/../../etc/passwd"), "/etc/passwd")
    }

    func testJoinAndParent() {
        XCTAssertEqual(RemotePath.join("/", "a"), "/a")
        XCTAssertEqual(RemotePath.join("/a", "b"), "/a/b")
        XCTAssertNil(RemotePath.parent(of: "/"))
        XCTAssertEqual(RemotePath.parent(of: "/a/b"), "/a")
        XCTAssertEqual(RemotePath.name(of: "/a/b.txt"), "b.txt")
        XCTAssertEqual(RemotePath.relative("/a/b"), "a/b")
    }
}

final class RemoteSyncErrorTests: XCTestCase {
    func testRetryableClassification() {
        XCTAssertTrue(RemoteSyncError.network("timeout").isRetryable)
        XCTAssertTrue(RemoteSyncError.rateLimited(retryAfter: 5).isRetryable)
        XCTAssertFalse(RemoteSyncError.authenticationFailed(reason: nil).isRetryable)
        XCTAssertFalse(RemoteSyncError.conflict(path: "/a").isRetryable)
        XCTAssertFalse(RemoteSyncError.cancelled.isRetryable)
    }

    func testCredentialDescriptionNeverLeaksSecret() {
        let credential = RemoteCredential.smb(username: "alice", password: "s3cret", domain: "HOME")
        XCTAssertFalse(credential.description.contains("s3cret"))
        XCTAssertTrue(credential.description.contains("alice"))
    }
}
