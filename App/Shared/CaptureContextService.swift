import CaptureCore
import Foundation
import HippoPresentation

/// Takes one context snapshot when a new capture begins and turns it into observations at save time.
/// One instance per process. Nothing here prompts, waits or throws.
@MainActor
final class CaptureContextService {
    static let shared = CaptureContextService()

    private var snapshot: ContextSnapshot?

    /// Call where a new capture starts (never for a comment). A no-op when the switch is off.
    func begin() {
        guard LocationService.settings.deviceContextEnabled else { snapshot = nil; return }
        snapshot = ContextSnapshot(takenAt: Date(), audioRoute: ContextReader.audioRoute(),
                                   device: ContextReader.device(), network: NetworkStatus.shared.current)
    }

    func observations(startedAt: Date) -> [MetadataObservation] {
        ContextPolicy.observations(enabled: LocationService.settings.deviceContextEnabled, snapshot: snapshot,
                                   captureStartedAt: startedAt, networkAtSave: NetworkStatus.shared.current)
    }
}
