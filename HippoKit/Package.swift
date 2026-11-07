// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HippoKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .library(name: "LocalRepository", targets: ["LocalRepository"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "FilesystemAdapter", targets: ["FilesystemAdapter"]),
    ],
    targets: [
        .target(name: "CaptureCore"),
        .target(name: "LocalRepository", dependencies: ["CaptureCore"]),
        .target(name: "SyncEngine", dependencies: ["CaptureCore", "LocalRepository"]),
        .target(name: "FilesystemAdapter", dependencies: ["SyncEngine", "CaptureCore"]),
        .target(name: "HippoTestSupport"),
        .executableTarget(name: "hippo-fixtures", dependencies: ["CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "LocalRepositoryTests", dependencies: ["LocalRepository", "CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine", "LocalRepository", "CaptureCore", "FilesystemAdapter"]),
        .testTarget(name: "AdapterContractTests", dependencies: ["FilesystemAdapter", "SyncEngine", "CaptureCore"]),
    ],
    swiftLanguageModes: [.v6]
)
