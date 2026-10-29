import Foundation

/// Locates the Python 3 interpreter used to launch the HTTP fixture servers.
///
/// Fixtures are test-only tooling: production modules never spawn processes and
/// never depend on Python. Previously the path was hard-coded to `/usr/bin/python3`,
/// which breaks on CI images that ship Python elsewhere (Homebrew, python.org,
/// `actions/setup-python`) and hides which interpreter actually ran the fixture.
///
/// Resolution order, first existing candidate wins:
///
/// 1. `BONE_PYTHON` environment variable (point it at any Python 3 executable).
/// 2. `/usr/bin/python3` (Apple Command Line Tools; the historical default).
/// 3. `/usr/local/bin/python3`, `/opt/homebrew/bin/python3` (Homebrew, Intel / Apple Silicon).
/// 4. `/opt/homebrew/opt/python@3/bin/python3`, `/usr/local/opt/python@3/bin/python3`.
/// 5. The first `python3` found on `PATH`.
///
/// When nothing resolves, `path` is nil and `unavailableReason` explains what to fix.
/// Callers turn that into an explicit, readable skip instead of a launch failure.
public enum PythonFixture {
    /// Absolute path to a Python 3 executable, or nil when none was found.
    public static let path: String? = resolve()

    /// True when a Python 3 interpreter was found, so fixture-backed suites can run.
    /// Usage: `@Suite(.enabled(if: PythonFixture.isAvailable, "需要 Python 3 启动 HTTP fixture"))`.
    public static let isAvailable = path != nil

    /// Human-readable explanation when `path` is nil; empty when Python was found.
    public static let unavailableReason: String = {
        guard path == nil else { return "" }
        let commandLineTools = "/Library/Developer/CommandLineTools"
        let hasTools = FileManager.default.fileExists(atPath: commandLineTools)
        return "没找到可用的 python3，HTTP fixture 测试需要 Python 3。"
            + (hasTools
                ? "已检测到 Command Line Tools，但 \(commandLineTools)/usr/bin/python3 不可执行。"
                : "可执行 `xcode-select --install` 安装 Command Line Tools，"
            )
            + "或用环境变量 BONE_PYTHON=/absolute/path/to/python3 显式指定。"
    }()

    /// `Process` executable URL for the fixture interpreter.
    ///
    /// - Throws: `PythonFixtureError.unavailable` carrying `unavailableReason`.
    public static func executableURL() throws -> URL {
        guard let path else { throw PythonFixtureError.unavailable(unavailableReason) }
        return URL(fileURLWithPath: path)
    }

    /// Pure resolution over an explicit environment and candidate list.
    ///
    /// Kept separate from the cached `path` so tests can prove the "no interpreter" branch
    /// without mutating the process environment or trying to hide system binaries.
    /// - Parameters:
    ///   - override: Value of `BONE_PYTHON`; used first when it names an executable file.
    ///   - fixedCandidates: Absolute locations probed in order.
    ///   - searchPath: `PATH` entries scanned for `python3` as a last resort.
    ///   - isExecutable: Filesystem predicate, injectable for testing.
    public static func resolve(
        override: String?,
        fixedCandidates: [String],
        searchPath: String?,
        isExecutable: (String) -> Bool = PythonFixture.isExecutableFile
    ) -> String? {
        var candidates: [String] = []
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(override)
        }
        candidates += fixedCandidates
        if let searchPath {
            for directory in searchPath.split(separator: ":") where !directory.isEmpty {
                candidates.append("\(directory)/python3")
            }
        }
        return candidates.first(where: isExecutable)
    }

    /// Absolute locations probed when `BONE_PYTHON` is unset or unusable.
    public static let fixedCandidates = [
        "/usr/bin/python3",
        "/usr/local/bin/python3",
        "/opt/homebrew/bin/python3",
        "/opt/homebrew/opt/python@3/bin/python3",
        "/usr/local/opt/python@3/bin/python3",
    ]

    private static func resolve() -> String? {
        resolve(
            override: ProcessInfo.processInfo.environment["BONE_PYTHON"],
            fixedCandidates: fixedCandidates,
            searchPath: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    /// Filesystem predicate: exists, is a regular file, and is executable.
    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

}

/// Failure raised when a fixture server cannot be started because no interpreter exists.
public enum PythonFixtureError: Error, CustomStringConvertible {
    case unavailable(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}
