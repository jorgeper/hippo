import Foundation
import CaptureCore
import LocalRepository

/// Where one enrichment step stands for one capture, worked out from its task row, the switches and
/// connectivity (design §5). Never from the log.
public enum StepState: Equatable, Sendable {
    case working
    case waiting(code: String?)
    /// Data detection is done but an input (transcript, text in image) hasn't landed yet.
    case waitingForInput(FacetKind)
    case done
    case nothingFound
    case failed(code: String?)
    case off
}

/// What a timeline row shows beside the sync dot.
public enum RowProgress: Equatable, Sendable {
    case none, working, waiting
}

public struct PendingLine: Equatable, Sendable {
    public var text: String
    public var working: Bool
    public init(text: String, working: Bool) { self.text = text; self.working = working }
}

public enum EnrichmentProgress {
    /// Kinds that need the network. HippoPresentation doesn't link `Enrichment`, so the list lives here.
    public static let networkKinds: Set<FacetKind> = [.linkPreview, .place]

    public static func steps(_ tasks: [EnrichmentTask], isEnabled: (FacetKind) -> Bool, isOnline: Bool,
                             now: Date) -> [FacetKind: StepState] {
        var out: [FacetKind: StepState] = [:]
        for t in tasks {
            switch t.status {
            case "ok": out[t.kind] = .done
            case "empty": out[t.kind] = .nothingFound
            case "failed": out[t.kind] = .failed(code: t.lastErrorCode)
            case "pending":
                if !isEnabled(t.kind) { out[t.kind] = .off }
                else if let next = t.nextAttemptAt, next > now { out[t.kind] = .waiting(code: t.lastErrorCode) }
                else if networkKinds.contains(t.kind), !isOnline { out[t.kind] = .waiting(code: "offline") }
                else { out[t.kind] = .working }
            default: break  // not_applicable, or a status a later version adds
            }
        }
        if out[.dataDetection] == .done || out[.dataDetection] == .nothingFound {
            for input in [FacetKind.transcript, .textRecognition] {
                switch out[input] {
                case .working?, .waiting?: out[.dataDetection] = .waitingForInput(input); return out
                default: continue
                }
            }
        }
        return out
    }

    public static func row(_ steps: [FacetKind: StepState]) -> RowProgress {
        var waiting = false
        for state in steps.values {
            switch state {
            case .working: return .working
            case .waiting: waiting = true
            case .waitingForInput(let input):
                if steps[input] == .working { return .working }
                waiting = true
            default: break
            }
        }
        return waiting ? .waiting : .none
    }

    static func kindName(_ kind: FacetKind) -> String {
        switch kind {
        case .linkPreview: "Link preview"
        case .place: "Place"
        case .transcript: "Transcript"
        case .textRecognition: "Text in image"
        case .dataDetection: "Dates, phone numbers and addresses"
        case .sourceAppGuess: "App guess"
        default: kind.rawValue
        }
    }

    /// The line Detail shows where the result will appear. Nil for finished states, and for the app
    /// guess while it works (too fast to show).
    public static func pendingLine(_ kind: FacetKind, _ state: StepState) -> PendingLine? {
        let name = kindName(kind)
        switch state {
        case .working:
            let text: String? = switch kind {
            case .linkPreview: "Fetching link preview…"
            case .place: "Looking up the place…"
            case .transcript: "Transcribing…"
            case .textRecognition: "Reading text in the image…"
            case .dataDetection: "Looking for dates, phone numbers and addresses…"
            default: nil
            }
            return text.map { PendingLine(text: $0, working: true) }
        case .waiting(let code):
            let reason: String = switch (code, kind) {
            case ("offline", _): "waiting for a connection"
            case ("throttled", .place): "Apple Maps is busy, will retry"
            case ("model_missing", .transcript): "waiting for the speech model to download"
            default: "couldn't finish yet. Hippo will retry."
            }
            return PendingLine(text: "\(name): \(reason)", working: false)
        case .waitingForInput(let input):
            let after = input == .transcript ? "the transcript" : "the image text"
            return PendingLine(text: "\(name): will check again after \(after)", working: false)
        case .done, .nothingFound, .failed, .off:
            return nil
        }
    }
}
