import Foundation

/// One shared attachment, as the intake sees it. `SystemItemProvider` wraps the real `NSItemProvider`;
/// tests use a fake.
public protocol ItemProviding: Sendable {
    var registeredTypeIdentifiers: [String] { get }
    var suggestedName: String? { get }
    /// Copies the file representation of `typeIdentifier` to `destination`. The copy finishes inside the
    /// provider's callback, while the provider still grants access to its temporary file.
    func copyFile(typeIdentifier: String, to destination: URL) async throws
    func loadURL() async throws -> URL
    func loadText() async throws -> String
}

/// Wraps an `NSItemProvider`. File types are only ever loaded as file representations, never into memory.
public struct SystemItemProvider: ItemProviding, @unchecked Sendable {
    struct MissingItem: Error {}

    private let provider: NSItemProvider

    public init(_ p: NSItemProvider) { provider = p }

    public var registeredTypeIdentifiers: [String] { provider.registeredTypeIdentifiers }
    public var suggestedName: String? { provider.suggestedName }

    public func copyFile(typeIdentifier: String, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else { continuation.resume(throwing: error ?? MissingItem()); return }
                // The provider deletes its temporary file when this handler returns, so copy now.
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func loadURL() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? MissingItem()) }
            }
        }
    }

    public func loadText() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text { continuation.resume(returning: text) } else { continuation.resume(throwing: error ?? MissingItem()) }
            }
        }
    }
}
