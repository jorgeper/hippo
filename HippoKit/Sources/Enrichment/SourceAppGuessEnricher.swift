import Foundation
import CaptureCore

/// Guesses which app a share came from, from factual clues in the bronze metadata (design §5.6).
public struct SourceAppGuessEnricher: Enricher {
    public struct Rule: Sendable, Equatable {
        public enum Match: Sendable, Equatable {
            case typeIdentifierPrefix(String)
            case filenamePrefix(String)
            case host([String])
        }
        public var app: String
        public var match: Match
        public var reason: String
        public init(app: String, match: Match, reason: String) { self.app = app; self.match = match; self.reason = reason }
    }

    /// Ordered; the first match wins. Rows confirmed on a device are added here (acceptance row E8).
    public static let rules: [Rule] = [
        Rule(app: "WhatsApp", match: .typeIdentifierPrefix("net.whatsapp."), reason: "uti:net.whatsapp"),
        Rule(app: "WhatsApp", match: .filenamePrefix("WhatsApp "), reason: "filename:whatsapp"),
        Rule(app: "Messages", match: .typeIdentifierPrefix("com.apple.mobilesms"), reason: "uti:messages"),
        Rule(app: "Messages", match: .typeIdentifierPrefix("com.apple.messages"), reason: "uti:messages"),
        Rule(app: "YouTube", match: .host(["youtube.com", "youtu.be"]), reason: "host:youtube"),
        Rule(app: "Safari", match: .typeIdentifierPrefix("com.apple.mobilesafari"), reason: "uti:safari"),
        Rule(app: "Photos", match: .filenamePrefix("IMG_"), reason: "filename:img"),
    ]

    public var kind: FacetKind { .sourceAppGuess }
    public var version: Int { 1 }
    public var usesNetwork: Bool { false }
    public var inputs: Set<FacetKind> { [] }

    public init() {}

    public func applies(to m: CaptureMetadata) -> Bool { m.captureMethod == .shareExtension }

    public func run(_ input: EnricherInput) async throws -> EnricherOutput {
        let m = input.metadata
        let typeIDs = Self.strings(m.metadataObservations.first { $0.key == "share.registered_type_identifiers" }?.value)
        var names = Self.strings(m.metadataObservations.first { $0.key == "share.suggested_names" }?.value)
        names += m.attachments.compactMap(\.originalFilename)
        let hosts = m.urls.compactMap { URL(string: $0.url)?.host?.lowercased() }.map(Self.stripped)

        for rule in Self.rules {
            let hit: Bool
            switch rule.match {
            case .typeIdentifierPrefix(let p): hit = typeIDs.contains { $0.lowercased().hasPrefix(p.lowercased()) }
            case .filenamePrefix(let p): hit = names.contains { $0.lowercased().hasPrefix(p.lowercased()) }
            case .host(let list): hit = hosts.contains { h in list.contains { h == $0 || h.hasSuffix("." + $0) } }
            }
            if hit {
                return EnricherOutput(status: .ok, data: try .payload(SourceAppGuessData(app: rule.app, reason: rule.reason)),
                                      provenance: "heuristic")
            }
        }
        return EnricherOutput(status: .empty, data: nil, provenance: "heuristic")
    }

    /// Flattens strings out of nested arrays, ignoring nulls and other values.
    private static func strings(_ v: JSONValue?) -> [String] {
        switch v {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap { strings($0) }
        default: return []
        }
    }

    private static func stripped(_ host: String) -> String {
        for p in ["www.", "m."] where host.hasPrefix(p) { return String(host.dropFirst(p.count)) }
        return host
    }
}
