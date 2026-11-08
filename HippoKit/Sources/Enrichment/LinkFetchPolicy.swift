import Foundation

public enum LinkFetchDecision: Equatable, Sendable {
    case youTube(videoURL: URL)
    case fetch
    case skip(reason: String)
}

/// Decides whether a saved link may be fetched (design §5.1). Saved links are often one-time (unsubscribe,
/// magic login, password reset), so anything that looks single-use, or that points inside a private network,
/// is never fetched.
public enum LinkFetchPolicy {
    static let singleUseQueryKeys: Set<String> = ["token", "code", "key", "sig", "signature", "auth", "otp", "magic"]
    static let singleUsePathWords = ["unsubscribe", "login", "verify", "reset", "confirm"]
    private static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com"]

    public static func decide(_ url: URL) -> LinkFetchDecision {
        if let video = youTubeVideoURL(url) { return .youTube(videoURL: video) }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .skip(reason: "scheme")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty, !isPrivate(host) else {
            return .skip(reason: "private_host")
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { singleUseQueryKeys.contains($0.name.lowercased()) }) {
            return .skip(reason: "single_use")
        }
        let path = url.path(percentEncoded: false).lowercased()
        if singleUsePathWords.contains(where: { path.contains($0) }) { return .skip(reason: "single_use") }
        return .fetch
    }

    private static func youTubeVideoURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        if host == "youtu.be" { return parts.count >= 1 && !parts[0].isEmpty ? url : nil }
        guard youTubeHosts.contains(host) else { return nil }
        if parts.count == 1, parts[0] == "watch",
           let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty { return url }
        if parts.count >= 2, parts[0] == "shorts", !parts[1].isEmpty { return url }
        return nil
    }

    /// Names that only resolve inside a home or company network.
    private static let privateSuffixes = ["localhost", "local", "lan", "internal", "home.arpa"]

    /// IP literals of any kind (public ones too), dotless names (`router`), and `localhost`, `.local`,
    /// `.lan`, `.internal` and `.home.arpa` names.
    static func isPrivate(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if host.contains(":") { return true }   // IPv6 literal (hostnames cannot contain a colon)
        if !host.contains(".") { return true }  // a dotless name resolves only on the local network
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        // Shorthand IPv4 forms (`2130706433`, `0x7f.1`): a host whose labels are all numeric or hex.
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if !labels.isEmpty, labels.allSatisfy({ l in
            !l.isEmpty && (l.allSatisfy(\.isNumber) || (l.hasPrefix("0x") && l.dropFirst(2).allSatisfy(\.isHexDigit)))
        }) { return true }
        return false
    }
}
