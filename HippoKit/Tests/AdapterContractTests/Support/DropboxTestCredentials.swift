import Foundation

/// Credentials for the real-Dropbox contract test, read from the gitignored `.env` found by walking up from this file.
/// Never printed.
enum DropboxTestCredentials {
    private static let values: [String: String] = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(".env")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { return parse(text) }
            dir = dir.deletingLastPathComponent()
        }
        return [:]
    }()

    private static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { out[key] = value }
        }
        return out
    }

    static let appKey: String? = values["HIPPO_DROPBOX_APP_KEY"].flatMap { $0 == "your_app_key" ? nil : $0 }
    static let refreshToken: String? = values["HIPPO_DROPBOX_REFRESH_TOKEN"].flatMap { $0 == "your_refresh_token" ? nil : $0 }
    static var available: Bool { appKey != nil && refreshToken != nil }
}
