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
        // 推荐统一入口：一次导入契约与全部已实现来源。
        .library(name: "BoneRemoteSyncKit", targets: ["BoneRemoteSyncKit"]),
        // 分模块产品用于按需依赖，不作为旧版兼容层。
        // 契约层：所有来源共用，零依赖。
        .library(name: "BoneRemoteSyncCore", targets: ["BoneRemoteSyncCore"]),
        // 普通本地目录来源；iCloud 使用独立协调适配器。
        .library(name: "BoneRemoteSyncLocal", targets: ["BoneRemoteSyncLocal"]),
        .library(name: "BoneRemoteSyncICloud", targets: ["BoneRemoteSyncICloud"]),
        .library(name: "BoneRemoteSyncWebDAV", targets: ["BoneRemoteSyncWebDAV"]),
        .library(name: "BoneRemoteSyncOneDrive", targets: ["BoneRemoteSyncOneDrive"]),
        .library(name: "BoneRemoteSyncCatalog", targets: ["BoneRemoteSyncCatalog"]),
        // 通用文件物化与传输任务层；不包含文件格式或宿主业务。
        .library(name: "BoneRemoteSyncTransfer", targets: ["BoneRemoteSyncTransfer"]),
    ],
    targets: [
        .target(
            name: "BoneRemoteSyncKit",
            dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncLocal", "BoneRemoteSyncICloud", "BoneRemoteSyncWebDAV", "BoneRemoteSyncOneDrive", "BoneRemoteSyncCatalog", "BoneRemoteSyncTransfer"]
        ),
        .target(name: "BoneRemoteSyncCatalog",
                dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncLocal", "BoneRemoteSyncWebDAV", "BoneRemoteSyncOneDrive"],
                linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("Security")]),
        .testTarget(name: "BoneRemoteSyncCatalogTests", dependencies: ["BoneRemoteSyncCatalog"]),
        .target(name: "BoneRemoteSyncCore"),
        .target(name: "BoneRemoteSyncLocal", dependencies: ["BoneRemoteSyncCore"]),
        .target(name: "BoneRemoteSyncICloud", dependencies: ["BoneRemoteSyncCore"]),
        .target(name: "BoneRemoteSyncWebDAV", dependencies: ["BoneRemoteSyncCore"]),
        .target(name: "BoneRemoteSyncOneDrive", dependencies: ["BoneRemoteSyncCore"], linkerSettings: [.linkedFramework("Security")]),
        .target(name: "BoneRemoteSyncTransfer", dependencies: ["BoneRemoteSyncCore"]),
        .testTarget(name: "BoneRemoteSyncKitTests", dependencies: ["BoneRemoteSyncKit"]),
        .testTarget(name: "BoneRemoteSyncTransferTests", dependencies: ["BoneRemoteSyncTransfer", "BoneRemoteSyncLocal", "BoneRemoteSyncTestSupport"]),
        .testTarget(name: "BoneRemoteSyncTestSupport"),
        .testTarget(name: "BoneRemoteSyncOneDriveTests",
                    dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncOneDrive", "BoneRemoteSyncCatalog", "BoneRemoteSyncTransfer", "BoneRemoteSyncTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(
            name: "BoneRemoteSyncWebDAVTests",
            dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncWebDAV", "BoneRemoteSyncTransfer", "BoneRemoteSyncTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BoneRemoteSyncCoreTests",
            dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncLocal"]
        ),
        .testTarget(
            name: "BoneRemoteSyncICloudTests",
            dependencies: ["BoneRemoteSyncCore", "BoneRemoteSyncICloud", "BoneRemoteSyncTransfer"]
        ),
    ]
)
