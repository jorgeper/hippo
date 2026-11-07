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
        .executableTarget(name: "hippo-fixtures", dependencies: ["CaptureCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
        .testTarget(name: "LocalRepositoryTests", dependencies: ["LocalRepository", "CaptureCore"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine", "LocalRepository", "CaptureCore"]),
        .testTarget(name: "AdapterContractTests", dependencies: ["FilesystemAdapter", "SyncEngine", "CaptureCore"]),
    ],
    swiftLanguageModes: [.v6]
)
