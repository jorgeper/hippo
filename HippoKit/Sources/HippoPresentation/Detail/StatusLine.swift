import Foundation
import CaptureCore

public enum StatusState: Equatable, Sendable { case done, working, waiting, failed }

/// One plain line of Detail's Status section, with its stripe layer (design §6.1).
public struct StatusLine: Equatable, Sendable {
    public var layer: Layer
    public var text: String
    public var state: StatusState
    public init(layer: Layer, text: String, state: StatusState) { self.layer = layer; self.text = text; self.state = state }

    private static let order: [FacetKind] = [.linkPreview, .place, .transcript, .textRecognition, .dataDetection,
                                             .sourceAppGuess]

    public static func lines(saved: Date, steps: [FacetKind: StepState], goldKinds: Set<FacetKind>,
                             goldArrivedAt: Date?, locale: Locale, zone: TimeZone) -> [StatusLine] {
        var out = [StatusLine(layer: .bronze,
                              text: "Saved on this iPhone · \(DetailFormat.dateTime(saved, zone: zone, locale: locale))",
                              state: .done)]
        for kind in order {
            guard let step = steps[kind] else { continue }
            let name = EnrichmentProgress.kindName(kind)
            let text: String, state: StatusState
            switch step {
            case .done: (text, state) = ("\(name): done", .done)
            case .nothingFound: (text, state) = ("\(name): nothing found", .done)
            case .off: (text, state) = ("\(name): off in Settings", .done)
            case .failed(let code):
                let reason = code.flatMap(reasonText).map { " — \($0)" } ?? ""
                (text, state) = ("\(name): couldn't \(verb(kind))\(reason)", .failed)
            case .working:
                (text, state) = (EnrichmentProgress.pendingLine(kind, step)?.text ?? "\(name): working", .working)
            case .waiting, .waitingForInput:
                (text, state) = (EnrichmentProgress.pendingLine(kind, step)?.text ?? "\(name): waiting", .waiting)
            }
            out.append(StatusLine(layer: goldKinds.contains(kind) ? .gold : .silver, text: text, state: state))
        }
        if let arrived = goldArrivedAt {
            out.append(StatusLine(layer: .gold,
                                  text: "From your server · \(DetailFormat.dateTime(arrived, zone: zone, locale: locale))",
                                  state: .done))
        }
        return out
    }

    private static func verb(_ kind: FacetKind) -> String {
        switch kind {
        case .linkPreview: "fetch the page"
        case .place: "look up the place"
        case .transcript: "transcribe"
        case .textRecognition: "read the text"
        case .dataDetection: "check"
        default: "finish"
        }
    }

    private static func reasonText(_ code: String) -> String? {
        switch code {
        case "http_4xx", "http_5xx": "the page didn't respond"
        case "too_large": "the file is too large"
        case "bad_url": "the link isn't valid"
        default: nil
        }
    }
}
