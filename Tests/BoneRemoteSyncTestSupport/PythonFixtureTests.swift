import Foundation
import Testing
@testable import BoneRemoteSyncTestSupport

/// Proves the interpreter resolution contract used by every fixture-backed suite.
///
/// The branch that matters most is "no interpreter at all": on a machine without
/// Python, suites must be skipped with a readable reason instead of crashing or
/// failing to launch a process. That branch cannot be exercised by hiding the real
/// `/usr/bin/python3` (system binaries are protected), so it is tested through the
/// injected `isExecutable` predicate.
@Suite struct PythonFixtureTests {
    @Test func overrideWinsWhenExecutable() {
        let resolved = PythonFixture.resolve(
            override: "/custom/bin/python3",
            fixedCandidates: ["/usr/bin/python3"],
            searchPath: "/usr/bin",
            isExecutable: { _ in true }
        )
        #expect(resolved == "/custom/bin/python3")
    }

    @Test func blankOverrideIsIgnoredAndFallsThrough() {
        let resolved = PythonFixture.resolve(
            override: "   ",
            fixedCandidates: ["/usr/bin/python3"],
            searchPath: nil,
            isExecutable: { $0 == "/usr/bin/python3" }
        )
        #expect(resolved == "/usr/bin/python3")
    }

    @Test func unusableOverrideFallsThroughToFixedCandidates() {
        let resolved = PythonFixture.resolve(
            override: "/missing/python3",
            fixedCandidates: ["/usr/bin/python3", "/opt/homebrew/bin/python3"],
            searchPath: nil,
            isExecutable: { $0 == "/opt/homebrew/bin/python3" }
        )
        #expect(resolved == "/opt/homebrew/bin/python3")
    }

    @Test func pathIsLastResort() {
        let resolved = PythonFixture.resolve(
            override: nil,
            fixedCandidates: ["/usr/bin/python3"],
            searchPath: "/nope::/tools/bin:",
            isExecutable: { $0 == "/tools/bin/python3" }
        )
        #expect(resolved == "/tools/bin/python3")
    }

    @Test func fixedCandidatesAreProbedBeforePath() {
        let resolved = PythonFixture.resolve(
            override: nil,
            fixedCandidates: ["/usr/bin/python3"],
            searchPath: "/tools/bin",
            isExecutable: { _ in true }
        )
        #expect(resolved == "/usr/bin/python3")
    }

    @Test func noInterpreterAnywhereResolvesToNil() {
        let resolved = PythonFixture.resolve(
            override: "/missing/python3",
            fixedCandidates: PythonFixture.fixedCandidates,
            searchPath: "/nope:/also-nope",
            isExecutable: { _ in false }
        )
        #expect(resolved == nil)
    }

    @Test func unavailableExecutableURLExplainsWhatToFix() throws {
        // Only assertable when this machine genuinely has no interpreter; otherwise the
        // positive path is what applies and the skip reason is empty by contract.
        if PythonFixture.isAvailable {
            #expect(PythonFixture.unavailableReason.isEmpty)
            let url = try PythonFixture.executableURL()
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
        } else {
            #expect(!PythonFixture.unavailableReason.isEmpty)
            #expect(throws: PythonFixtureError.self) { try PythonFixture.executableURL() }
        }
    }

    @Test func resolvedPathIsAbsoluteAndExecutable() throws {
        guard PythonFixture.isAvailable else { return }
        let path = try #require(PythonFixture.path)
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }
}
