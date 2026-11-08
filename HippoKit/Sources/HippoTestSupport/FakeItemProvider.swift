import Foundation
import Synchronization
import ShareIntake

/// An `ItemProviding` for tests. It records every call it receives, writes `fileBytes` on `copyFile`,
/// and returns `url` / `text` from the loads.
///
/// With `fails: true` every load throws. `copyFile` first writes half of `fileBytes`, to simulate a copy
/// that was interrupted part way through.
public final class FakeProvider: ItemProviding {
    public enum Call: Equatable, Sendable {
        case copyFile(String)
        case loadURL
        case loadText
    }

    public struct Failure: Error {}

    public let registeredTypeIdentifiers: [String]
    public let suggestedName: String?
    private let fileBytes: Data
    private let url: URL?
    private let text: String?
    private let fails: Bool
    private let recorded = Mutex<[Call]>([])

    public init(types: [String], suggestedName: String? = nil, fileBytes: Data = Data(), url: URL? = nil,
                text: String? = nil, fails: Bool = false) {
        registeredTypeIdentifiers = types; self.suggestedName = suggestedName
        self.fileBytes = fileBytes; self.url = url; self.text = text; self.fails = fails
    }

    /// The calls received so far, in order.
    public var calls: [Call] { recorded.withLock { $0 } }

    public func copyFile(typeIdentifier: String, to destination: URL) async throws {
        recorded.withLock { $0.append(.copyFile(typeIdentifier)) }
        if fails {
            try fileBytes.prefix(fileBytes.count / 2).write(to: destination)
            throw Failure()
        }
        try fileBytes.write(to: destination)
    }

    public func loadURL() async throws -> URL {
        recorded.withLock { $0.append(.loadURL) }
        guard !fails, let url else { throw Failure() }
        return url
    }

    public func loadText() async throws -> String {
        recorded.withLock { $0.append(.loadText) }
        guard !fails, let text else { throw Failure() }
        return text
    }
}
