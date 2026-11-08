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
        .library(name: "ShareIntake", targets: ["ShareIntake"]),
        .library(name: "HippoPresentation", targets: ["HippoPresentation"]),
        .library(name: "Enrichment", targets: ["Enrichment"]),
    ],
    targets: [
        .target(name: "CaptureCore"),
        .target(name: "LocalRepository", dependencies: ["CaptureCore"]),
        .target(name: "SyncEngine", dependencies: ["CaptureCore", "LocalRepository"]),
        .target(name: "FilesystemAdapter", dependencies: ["SyncEngine", "CaptureCore"]),
        .target(name: "ShareIntake", dependencies: ["CaptureCore"]),
        .target(name: "HippoPresentation", dependencies: ["CaptureCore", "LocalRepository", "SyncEngine", "ShareIntake"]),
        .target(name: "Enrichment", dependencies: ["CaptureCore", "LocalRepository"]),
        .target(name: "HippoTestSupport", dependencies: ["ShareIntake"]),
        .executableTarget(name: "hippo-fixtures", dependencies: ["CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "LocalRepositoryTests", dependencies: ["LocalRepository", "CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "SyncEngineTests", dependencies: ["SyncEngine", "LocalRepository", "CaptureCore", "FilesystemAdapter",
                                                    "HippoTestSupport"]),
        .testTarget(name: "AdapterContractTests", dependencies: ["FilesystemAdapter", "SyncEngine", "CaptureCore"]),
        .testTarget(name: "ShareIntakeTests", dependencies: ["ShareIntake", "CaptureCore", "HippoTestSupport"]),
        .testTarget(name: "HippoPresentationTests", dependencies: ["HippoPresentation", "CaptureCore", "LocalRepository",
                                                                   "SyncEngine", "FilesystemAdapter", "HippoTestSupport", "ShareIntake"]),
        .testTarget(name: "EnrichmentTests", dependencies: ["Enrichment", "CaptureCore", "LocalRepository", "SyncEngine",
                                                            "HippoTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
