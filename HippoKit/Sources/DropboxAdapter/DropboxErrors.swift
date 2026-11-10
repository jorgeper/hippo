import Foundation
import SyncEngine

/// A non-2xx Dropbox response, reduced to what callers branch on. Carries no body text.
public struct DropboxCallError: Error, Equatable, Sendable {
    public var status: Int
    /// The `.tag` chain, flattened depth-first through `error`, e.g. `["path", "conflict", "file"]`.
    public var tags: [String]
    public var retryAfter: TimeInterval?
    public var correctOffset: Int64?

    public init(status: Int, tags: [String] = [], retryAfter: TimeInterval? = nil, correctOffset: Int64? = nil) {
        self.status = status
        self.tags = tags
        self.retryAfter = retryAfter
        self.correctOffset = correctOffset
    }

    /// Tolerates missing or odd shapes: unparseable input gives empty tags.
    public init(status: Int, headers: [String: String], body: Data) {
        var tags: [String] = []
        var correct: Int64?
        var bodyRetry: TimeInterval?
        if let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let error = object["error"] as? [String: Any] {
            var node: [String: Any]? = error
            var depth = 0
            while let current = node, depth < 8 {
                depth += 1
                guard let tag = current[".tag"] as? String else { break }
                tags.append(tag)
                if let n = current["correct_offset"] as? NSNumber { correct = n.int64Value }
                if let n = current["retry_after"] as? NSNumber { bodyRetry = n.doubleValue }
                // `reason` (UploadWriteFailed) then `path`, then the tag's own key, then any nested object.
                // Only `.tag` strings are collected, so fields like `upload_session_id` never reach a tag.
                node = (current["reason"] as? [String: Any]) ?? (current["path"] as? [String: Any])
                    ?? (current[tag] as? [String: Any]) ?? current.values.compactMap { $0 as? [String: Any] }.first
            }
            if let n = error["retry_after"] as? NSNumber { bodyRetry = n.doubleValue }
        }
        self.init(status: status, tags: tags,
                  retryAfter: headers["retry-after"].flatMap { Double($0) } ?? bodyRetry,
                  correctOffset: correct)
    }

    /// `[a-z0-9_:.-]{1,64}`, so the code survives `Diagnostics.safeCode`.
    private static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_:.-")
        let cleaned = String(s.lowercased().map { allowed.contains($0) ? $0 : "." }.prefix(64))
        return cleaned.isEmpty ? "unrecognized" : cleaned
    }

    public func storageError() -> StorageError {
        if status == 401 { return .needsAuthentication }
        if status == 429 || tags.contains("too_many_write_operations") || tags.contains("too_many_requests") {
            return .rateLimited(retryAfter: retryAfter ?? 1)
        }
        if tags.contains("insufficient_space") { return .quotaExceeded }
        if (500..<600).contains(status) { return .transient(code: "http_5xx") }
        if status == 409, !tags.isEmpty { return .permanent(code: Self.safe("api:" + tags.joined(separator: "."))) }
        return .transient(code: "http_\(status)")
    }
}
