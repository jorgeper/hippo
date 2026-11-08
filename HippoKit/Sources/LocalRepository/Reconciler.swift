import Foundation
import CaptureCore
import os

public struct RecoveryReport: Sendable, Equatable {
    /// Abandoned `staging/<id>` directories deleted.
    public var removedStaging = 0
    /// Committed packages that were missing from the index and are now registered.
    public var registered = 0
    /// Index rows whose package directory no longer exists (removed, with their jobs).
    public var orphanedIndexRows = 0
    /// Package directories that are not a valid complete package at their path. Left in place.
    public var invalidPackages = 0
    /// Unassigned captures bound to the active destination.
    public var boundToActive = 0
    /// Items (staging entries, rows, packages, the bind step) that failed and were skipped.
    public var failed = 0
}

/// Startup recovery (spec §4): the filesystem is the truth. Holds no state between runs, and is safe to
/// run repeatedly.
public final class Reconciler: Sendable {
    private static let log = Logger(subsystem: "com.jorgeper.hippo", category: "recovery")

    private let layout: StoreLayout
    private let index: CaptureIndex
    private let jobs: JobStore
    private let destinations: DestinationStore

    public init(layout: StoreLayout, index: CaptureIndex, jobs: JobStore, destinations: DestinationStore) {
        self.layout = layout; self.index = index; self.jobs = jobs; self.destinations = destinations
    }

    public func run() throws -> RecoveryReport {
        var report = RecoveryReport()
        // One bad item must not stop the rest of the run: each is isolated, counted and logged with a
        // fixed string (never IDs, paths or error text).
        removeAbandonedStaging(into: &report)

        // `failed` counts failed operations: a persistent DB failure counts once per listing and per register.
        // Drop rows whose package is gone, so the walk below can re-register a package that came back.
        do {
            for row in try index.indexedDirectories()
            where !FileManager.default.fileExists(atPath: layout.packageURL(relativeDirectory: row.relativeDirectory).path) {
                do {
                    try index.remove(captureID: row.captureID)
                    report.orphanedIndexRows += 1
                } catch { itemFailed(&report) }
            }
        } catch { itemFailed(&report) }

        let indexed: Set<String>
        do { indexed = Set(try index.indexedDirectories().map(\.captureID)) } catch { itemFailed(&report); indexed = [] }
        for directory in packageDirectories() where !indexed.contains(directory.lastPathComponent) {
            // `load` validates (hashing the package once) and checks the path.
            guard let package = CommittedPackage.load(directory: directory, layout: layout) else {
                report.invalidPackages += 1
                continue
            }
            do {
                if try index.register(package, noteBody: package.noteBody()) {
                    report.registered += 1
                    try jobs.enqueueIfActive(captureID: package.metadata.captureID)
                }
            } catch { itemFailed(&report) }
        }

        // The bind step always runs.
        do {
            if try destinations.active() != nil {
                report.boundToActive = try destinations.bindUnassignedToActive()
            }
        } catch { itemFailed(&report) }
        return report
    }

    private func itemFailed(_ report: inout RecoveryReport) {
        report.failed += 1
        Self.log.error("\("recover_item_failed", privacy: .public)")
    }

    // MARK: Staging

    /// Deletes every `staging/<id>` whose lock is free, and lock files with no directory. A lock held
    /// by a live writer (a package writer, or a gold pull's `staging/gold-<uuid>`) means "skip".
    /// `staging/enrichments/` is not a package: `EnrichmentStore.sweep()` owns it.
    private func removeAbandonedStaging(into report: inout RecoveryReport) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: layout.stagingDir.path) else { return }
        for name in names.sorted() where name != layout.enrichmentStagingDir.lastPathComponent {
            do {
                if name.hasSuffix(".lock") {
                    let dir = layout.stagingDir.appendingPathComponent(String(name.dropLast(5)))
                    if fm.fileExists(atPath: dir.path) { continue }  // handled with its directory
                    try StagingLock.tryAcquire(at: layout.stagingDir.appendingPathComponent(name))?.release()
                    continue
                }
                let dir = layout.stagingDir.appendingPathComponent(name, isDirectory: true)
                guard Self.isDirectory(dir),
                      let lock = try StagingLock.tryAcquire(at: layout.stagingDir.appendingPathComponent("\(name).lock"))
                else { continue }
                defer { lock.release() }
                // A writer may have renamed its directory away between the check and the lock.
                guard Self.isDirectory(dir) else { continue }
                do {
                    try fm.removeItem(at: dir)
                    report.removedStaging += 1
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Already gone.
                }
            } catch { itemFailed(&report) }
        }
    }

    // MARK: Walk

    /// `captures/YYYY/MM/DD/<id>` directories. Empty partitions and stray files are skipped silently.
    private func packageDirectories() -> [URL] {
        var level = [layout.capturesDir]
        for _ in 0..<4 {
            level = level.flatMap { parent in
                ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
                    .map { parent.appendingPathComponent($0, isDirectory: true) }
                    .filter(Self.isDirectory)
            }
        }
        return level
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
