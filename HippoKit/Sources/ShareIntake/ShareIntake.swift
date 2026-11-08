import Foundation
import UniformTypeIdentifiers
import CaptureCore

public struct IntakeFailure: Sendable, Equatable {
    public enum Kind: Sendable {
        /// The provider offers nothing Hippo can save.
        case unsupported
        /// Loading or copying threw.
        case loadFailed
    }

    /// Position of the provider in `ShareInput.providers`.
    public var index: Int
    public var kind: Kind

    public init(index: Int, kind: Kind) { self.index = index; self.kind = kind }
}

public struct IntakeResult: Sendable {
    public var draft: CaptureDraft
    public var failures: [IntakeFailure]
    /// Size of every attachment in the draft.
    public var totalBytes: Int64
    /// The first copied image, for a preview thumbnail.
    public var firstImageURL: URL?
}

/// Turns a share payload into a `CaptureDraft`. File representations are streamed into the capture's
/// intake directory; nothing is loaded into memory except URLs and text.
public struct ShareIntake: Sendable {
    static let largeTextLimit = 100_000
    static let provenance = "ns_extension_item"

    private let directory: IntakeDirectory

    public init(directory: IntakeDirectory) { self.directory = directory }

    public func prepare(_ input: ShareInput, captureID: UUID, startedAt: Date, timeZone: TimeZone,
                        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void) async -> IntakeResult {
        let fm = FileManager.default
        let folder = directory.directory(for: captureID)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var attachments: [AttachmentSource] = []
        var urls: [CapturedURL] = []
        var keptTexts: [String] = []
        var failures: [IntakeFailure] = []
        var totalBytes: Int64 = 0
        var firstImageURL: URL?

        let total = input.providers.count
        progress(0, total)
        for (index, provider) in input.providers.enumerated() {
            let plan = Self.plan(for: provider.registeredTypeIdentifiers)
            do {
                switch try await Self.take(provider, plan: plan, base: folder.appendingPathComponent("\(index)")) {
                case .file(let source, let url, let isImage, let bytes):
                    attachments.append(source)
                    totalBytes += bytes
                    if isImage, firstImageURL == nil { firstImageURL = url }
                case .link(let url, let text):
                    if !urls.contains(where: { $0.url == url }) {
                        urls.append(CapturedURL(url: url, source: "shared_payload"))
                    }
                    if let text { keptTexts.append(text) }
                case .text(let text):
                    if let text { keptTexts.append(text) }
                case nil:
                    failures.append(IntakeFailure(index: index, kind: .unsupported))
                }
            } catch {
                failures.append(IntakeFailure(index: index, kind: .loadFailed))
            }
            progress(index + 1, total)
        }

        var texts = keptTexts
        if let content = Self.nonBlank(input.contentText),
           !keptTexts.contains(content), !urls.contains(where: { $0.url == content }) {
            texts.insert(content, at: 0)
        }
        let joined = texts.joined(separator: "\n\n")
        var sharedText: String?
        if joined.utf8.count > Self.largeTextLimit {
            let data = Data(joined.utf8)
            attachments.append(AttachmentSource(body: .data(data), uti: "public.utf8-plain-text", mimeType: "text/plain",
                                                representationSource: "item_provider_data"))
            totalBytes += Int64(data.count)
        } else if !joined.isEmpty {
            sharedText = joined
        }

        let draft = CaptureDraft(captureID: captureID, startedAt: startedAt, timeZone: timeZone, method: .shareExtension,
                                 sharedTitle: Self.nonBlank(input.title), sharedText: sharedText, urls: urls,
                                 attachments: attachments, observations: Self.observations(input))
        return IntakeResult(draft: draft, failures: failures, totalBytes: totalBytes, firstImageURL: firstImageURL)
    }

    // MARK: - Classification

    enum Plan: Equatable {
        /// Copy this file representation.
        case file(identifier: String, type: UTType)
        /// The only URL offered is a file URL: copy the file it points to.
        case localFile
        /// A web (non-file) URL, plus its text when the provider also offers plain text.
        case link(withText: Bool)
        case text
        case unsupported
    }

    private static let richTextTypes: [UTType] = [.rtf, .rtfd, .flatRTFD, .html]

    /// Identifiers the system doesn't know conform to nothing, so they never classify as a file.
    static func plan(for identifiers: [String]) -> Plan {
        let types = identifiers.compactMap { id in UTType(id).map { (id, $0) } }
        let offersText = types.contains { $0.1.conforms(to: .plainText) }
        let file = types.first { _, type in
            type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .plainText)
                && !(offersText && richTextTypes.contains { type.conforms(to: $0) })
        }
        if let (id, type) = file { return .file(identifier: id, type: type) }
        let urlTypes = types.map(\.1).filter { $0.conforms(to: .url) }
        if !urlTypes.isEmpty, urlTypes.allSatisfy({ $0 == .fileURL }) { return .localFile }
        if !urlTypes.isEmpty { return .link(withText: offersText) }
        if offersText { return .text }
        return .unsupported
    }

    // MARK: - Loading

    enum Item {
        case file(AttachmentSource, url: URL, isImage: Bool, bytes: Int64)
        case link(String, text: String?)
        /// Nil when the text was blank.
        case text(String?)
    }

    /// Nil for an unsupported provider. `base` is the destination path without its extension.
    private static func take(_ provider: any ItemProviding, plan: Plan, base: URL) async throws -> Item? {
        switch plan {
        case .file(let identifier, let type):
            let destination = base.appendingPathExtension(fileExtension(type))
            do {
                try await provider.copyFile(typeIdentifier: identifier, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return fileItem(at: destination, uti: identifier, type: type, name: provider.suggestedName)

        case .localFile, .link:
            let url = try await provider.loadURL()
            if url.isFileURL { return try copyLocalFile(url, base: base, suggestedName: provider.suggestedName) }
            var text: String?
            if plan == .link(withText: true), let loaded = nonBlank(try await provider.loadText()),
               loaded != url.absoluteString {
                text = loaded
            }
            return .link(url.absoluteString, text: text)

        case .text:
            return .text(nonBlank(try await provider.loadText()))

        case .unsupported:
            return nil
        }
    }

    private static func copyLocalFile(_ source: URL, base: URL, suggestedName: String?) throws -> Item {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let destination = base.appendingPathExtension(fileExtension(type))
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return fileItem(at: destination, uti: type.identifier, type: type,
                        name: suggestedName ?? source.lastPathComponent)
    }

    private static func fileItem(at url: URL, uti: String, type: UTType, name: String?) -> Item {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let source = AttachmentSource(body: .file(url), originalFilename: name, uti: uti, mimeType: type.preferredMIMEType,
                                      representationSource: "item_provider_file")
        return .file(source, url: url, isImage: type.conforms(to: .image), bytes: size)
    }

    private static func fileExtension(_ type: UTType) -> String { type.preferredFilenameExtension ?? "bin" }

    private static func nonBlank(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Observations

    /// Factual clues about the sharing app (design §3.3). `userInfo` values are never recorded.
    static func observations(_ input: ShareInput) -> [MetadataObservation] {
        let types = input.providers.map { provider in
            JSONValue.array(provider.registeredTypeIdentifiers.prefix(32).map { .string(String($0.prefix(200))) })
        }
        let names = input.providers.map { provider in
            provider.suggestedName.map { JSONValue.string(String($0.prefix(255))) } ?? .null
        }
        var result = [
            MetadataObservation(key: "share.registered_type_identifiers", value: .array(types), provenance: provenance),
            MetadataObservation(key: "share.suggested_names", value: .array(names), provenance: provenance),
        ]
        let keys = input.userInfoKeys.map { String($0.prefix(100)) }.sorted().prefix(20)
        if !keys.isEmpty {
            result.append(MetadataObservation(key: "share.userinfo_keys", value: .array(keys.map { .string($0) }),
                                              provenance: provenance))
        }
        return result
    }
}
