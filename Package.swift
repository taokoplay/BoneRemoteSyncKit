// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoneRemoteSyncKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        // 契约层：所有来源共用，零依赖。
        .library(name: "BoneRemoteSyncCore", targets: ["BoneRemoteSyncCore"]),
        // 本地目录来源：同时作为测试桩，也是后续 iCloud 目录的来源基础。
        .library(name: "BoneRemoteSyncLocal", targets: ["BoneRemoteSyncLocal"]),
        .library(name: "BoneRemoteSyncWebDAV", targets: ["BoneRemoteSyncWebDAV"]),
        .library(name: "BoneRemoteSyncOneDrive", targets: ["BoneRemoteSyncOneDrive"]),
    ],
    targets: [
        .target(name: "BoneRemoteSyncCore"),
        .target(name: "BoneRemoteSyncLocal", dependencies: ["BoneRemoteSyncCore"]),
        .target(name: "BoneRemoteSyncWebDAV", dependencies: ["BoneRemoteSyncCore"]),
        .target(name: "BoneRemoteSyncOneDrive", dependencies: ["BoneRemoteSyncCore"]),
        .testTarget(name: "BoneRemoteSyncOneDriveTests",
                    dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncOneDrive"],
                    resources: [.copy("Fixtures")]),
        .testTarget(
            name: "BoneRemoteSyncWebDAVTests",
            dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncWebDAV"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BoneRemoteSyncCoreTests",
            dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncLocal"]
        ),
    ]
)
