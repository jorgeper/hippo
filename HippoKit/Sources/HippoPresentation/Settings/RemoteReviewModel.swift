import Foundation
import Observation
import os
import LocalRepository
import SyncEngine

/// The review sheet: captures that vanished from the destination (or the whole folder did), and what to
/// do about them. Nothing here deletes anything until the reader picks a button.
@MainActor @Observable
public final class RemoteReviewModel {
    public private(set) var items: [ReviewItem] = []
    public private(set) var dateRange: String?
    /// How many of the items have large files that now exist only in the destination.
    public private(set) var trimmedCount = 0
    public private(set) var destinationName = ""
    public private(set) var isPending = false
    /// True after a resolve failed; the sheet shows an alert and stays open.
    public var resolveFailed = false

    public var count: Int { items.count }
    public var title: String { "\(destinationName) looks different" }
    public var summaryLine: String {
        let noun = count == 1 ? "capture" : "captures"
        return ["\(count) \(noun)", dateRange].compactMap { $0 }.joined(separator: ", ")
    }
    public var trimmedLine: String { "\(trimmedCount) of these have large files only in \(destinationName)" }
    /// Every item has a trimmed file, so there is nothing to upload again.
    public var keepTitle: String { trimmedCount == count ? "Keep on iPhone as they are" : "Keep and upload again" }
    public static let removeTitle = "Remove them from iPhone"
    public static let laterTitle = "Decide later"
    public let footer = "You can restore deleted files on dropbox.com for a while."

    @ObservationIgnored private let store: HippoStore
    @ObservationIgnored private let sync: @Sendable () async -> Void
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var destinationID: String?
    private nonisolated static let log = Logger(subsystem: "com.jorgeper.hippo", category: "review")

    public init(store: HippoStore, sync: @escaping @Sendable () async -> Void, locale: Locale = .current,
                calendar: Calendar = .current) {
        self.store = store
        self.sync = sync
        self.locale = locale
        self.calendar = calendar
    }

    private struct Loaded: Sendable {
        var destination: Destination?
        var items: [ReviewItem]
        var earliest: Date?
        var latest: Date?
        var trimmed: Int
    }

    public func load() async {
        let store = store
        let loaded: Loaded? = await Task.detached {
            do {
                guard let destination = try store.destinations.active() else {
                    return Loaded(destination: nil, items: [], earliest: nil, latest: nil, trimmed: 0)
                }
                let items = try store.remoteState.reviewItems(destinationID: destination.id)
                let dates = try items.compactMap {
                    try store.index.metadata(captureID: $0.captureID, layout: store.layout)?.capturedAt
                }
                let trimmed = try store.trims.captureIDsWithTrimmed(in: items.map(\.captureID))
                return Loaded(destination: destination, items: items, earliest: dates.min(), latest: dates.max(),
                              trimmed: trimmed.count)
            } catch {
                Self.log.error("\("load_failed", privacy: .public)")
                return nil
            }
        }.value
        guard let loaded else { return }
        destinationID = loaded.destination?.id
        destinationName = loaded.destination?.displayName ?? ""
        items = loaded.items
        trimmedCount = loaded.trimmed
        isPending = loaded.destination != nil && !loaded.items.isEmpty
        dateRange = Self.range(loaded.earliest, loaded.latest, locale: locale, calendar: calendar)
    }

    /// Removes the listed captures from this iPhone; the destination is untouched.
    public func removeFromPhone() async {
        await resolve(keep: false)
    }

    /// Keeps the captures, uploads the ones without trimmed files again, then syncs.
    public func keepAndUploadAgain() async {
        await resolve(keep: true)
        await sync()
    }

    /// Leaves the review queue as it is.
    public func decideLater() {}

    private func resolve(keep: Bool) async {
        guard let id = destinationID else { return }
        let store = store
        do {
            _ = try await store.resolveReview(destinationID: id, keep: keep)
            resolveFailed = false
        } catch {
            Self.log.error("\("resolve_failed", privacy: .public)")
            resolveFailed = true
        }
        await load()
    }

    private static func range(_ earliest: Date?, _ latest: Date?, locale: Locale, calendar: Calendar) -> String? {
        guard let earliest, let latest else { return nil }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let sameDay = calendar.isDate(earliest, inSameDayAs: latest)
        return sameDay ? formatter.string(from: earliest, to: earliest) : formatter.string(from: earliest, to: latest)
    }
}
