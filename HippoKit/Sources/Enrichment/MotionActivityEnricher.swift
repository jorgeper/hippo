import Foundation
import CaptureCore

/// One Core Motion activity sample: when it started and the flags and confidence it carried.
public struct MotionSample: Sendable, Equatable {
    public var startedAt: Date
    public var activities: [String]
    public var confidence: String
    public init(startedAt: Date, activities: [String], confidence: String) {
        self.startedAt = startedAt; self.activities = activities; self.confidence = confidence
    }
}

public enum MotionHistoryError: Error, Sendable {
    /// Motion & Fitness access has not been granted.
    case unauthorized
    /// This device keeps no motion history.
    case unavailable
}

/// The activity history source (Core Motion in the app; a fake in tests).
public protocol MotionHistoryProviding: Sendable {
    func samples(from: Date, to: Date) async throws -> [MotionSample]
}

/// What the person was doing around a capture (design §5.1). Off until switched on. Waits until the
/// window after the capture has closed, and writes nothing once Core Motion's history has expired.
public struct MotionActivityEnricher: Enricher {
    public static let halfWindow: TimeInterval = 600
    public static let historyLimit: TimeInterval = 7 * 86_400
    public static let maxSegments = 60
    static let unauthorizedRetry: TimeInterval = 86_400
    /// The order flags are written in, whatever order the source raised them.
    static let activityOrder = ["stationary", "walking", "running", "cycling", "automotive", "unknown"]

    public var kind: FacetKind { .motionActivity }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var inputs: Set<FacetKind> { [] }

    private let history: any MotionHistoryProviding
    private let now: @Sendable () -> Date

    public init(history: any MotionHistoryProviding, now: @escaping @Sendable () -> Date = Date.init) {
        self.history = history; self.now = now
    }

    public func applies(to m: CaptureMetadata) -> Bool { true }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        let capturedAt = input.metadata.capturedAt
        let current = now()
        let windowClose = capturedAt.addingTimeInterval(Self.halfWindow)
        if current < windowClose {
            throw EnrichmentError.deferred(code: "motion_window_open", retryAfter: windowClose.timeIntervalSince(current))
        }
        if current.timeIntervalSince(capturedAt) > Self.historyLimit {
            throw EnrichmentError.notApplicable(code: "motion_history_expired")
        }
        let start = capturedAt.addingTimeInterval(-Self.halfWindow)

        let raw: [MotionSample]
        do {
            raw = try await history.samples(from: start, to: windowClose)
        } catch is CancellationError {
            throw CancellationError()
        } catch MotionHistoryError.unauthorized {
            throw EnrichmentError.deferred(code: "motion_unauthorized", retryAfter: Self.unauthorizedRetry)
        } catch MotionHistoryError.unavailable {
            throw EnrichmentError.notApplicable(code: "motion_unavailable")
        } catch {
            throw EnrichmentError.transient(code: "motion_query")
        }

        // Stable sort, so equal timestamps keep the source's order.
        let samples = raw.enumerated().sorted {
            $0.element.startedAt != $1.element.startedAt ? $0.element.startedAt < $1.element.startedAt : $0.offset < $1.offset
        }.map { sample -> MotionActivityData.Sample in
            MotionActivityData.Sample(startedAt: sample.element.startedAt,
                                      activities: Self.ordered(sample.element.activities),
                                      confidence: sample.element.confidence)
        }
        guard !samples.isEmpty else { return EnricherOutput(status: .empty, data: nil, provenance: "core_motion") }

        var merged: [MotionActivityData.Sample] = []
        for s in samples {
            if let last = merged.last, last.activities == s.activities, last.confidence == s.confidence { continue }
            merged.append(s)
        }
        let data = MotionActivityData(windowStart: start, windowEnd: windowClose,
                                      atCapture: samples.last { $0.startedAt <= capturedAt },
                                      segments: Array(merged.prefix(Self.maxSegments)))
        return EnricherOutput(status: .ok, data: try .payload(data), provenance: "core_motion")
    }

    private static func ordered(_ activities: [String]) -> [String] {
        // A sample with no flag raised is unknown: a facet never carries an empty activity list.
        let set = activities.isEmpty ? Set(["unknown"]) : Set(activities)
        let known = activityOrder.filter(set.contains)
        let other = set.subtracting(activityOrder).sorted()
        return known + other
    }
}
