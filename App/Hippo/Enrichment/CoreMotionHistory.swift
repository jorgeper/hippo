@preconcurrency import CoreMotion
import Foundation
import Enrichment

/// Activity history from Core Motion (design §5.1). Querying never prompts: it runs only when access is
/// already granted. `requestAccess()` is the one call that prompts. Main app only: the Share Extension
/// does not link this file.
final class CoreMotionHistory: MotionHistoryProviding {
    static var authorization: CMAuthorizationStatus { CMMotionActivityManager.authorizationStatus() }

    func samples(from: Date, to: Date) async throws -> [MotionSample] {
        guard CMMotionActivityManager.isActivityAvailable() else { throw MotionHistoryError.unavailable }
        guard Self.authorization == .authorized else { throw MotionHistoryError.unauthorized }
        return try await Self.query(from: from, to: to)
    }

    /// Asks for Motion & Fitness access with a short query, which is how Core Motion prompts. True when
    /// access ended up granted.
    static func requestAccess() async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        let end = Date()
        _ = try? await query(from: end.addingTimeInterval(-60), to: end)
        return authorization == .authorized
    }

    private static func query(from: Date, to: Date) async throws -> [MotionSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[MotionSample], Error>) in
            // One manager per query; the handler holds it until Core Motion answers.
            let manager = CMMotionActivityManager()
            manager.queryActivityStarting(from: from, to: to, to: OperationQueue()) { activities, error in
                withExtendedLifetime(manager) {}
                if let error = error as NSError? {
                    let denied = error.domain == CMErrorDomain && error.code == Int(CMErrorMotionActivityNotAuthorized.rawValue)
                    continuation.resume(throwing: denied ? MotionHistoryError.unauthorized : error)
                    return
                }
                continuation.resume(returning: (activities ?? []).map(sample))
            }
        }
    }

    private static func sample(_ a: CMMotionActivity) -> MotionSample {
        var flags: [String] = []
        if a.stationary { flags.append("stationary") }
        if a.walking { flags.append("walking") }
        if a.running { flags.append("running") }
        if a.cycling { flags.append("cycling") }
        if a.automotive { flags.append("automotive") }
        // Core Motion reports `unknown` as its own flag; a sample with no flag raised is unknown too.
        if a.unknown || flags.isEmpty { flags.append("unknown") }
        let confidence: String
        switch a.confidence {
        case .low: confidence = "low"
        case .medium: confidence = "medium"
        case .high: confidence = "high"
        @unknown default: confidence = "low"
        }
        return MotionSample(startedAt: a.startDate, activities: flags, confidence: confidence)
    }
}
