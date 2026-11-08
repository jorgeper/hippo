import Foundation

/// When two captured links are the same page. Apps add share-tracking parameters (Instagram offers a reel
/// twice, once with `?l=1`), so links are compared with those removed and the host lowercased.
public enum LinkIdentity {
    /// Query parameters that only track the share, on any host. `utm_` is a prefix.
    static let trackingNames: Set<String> = ["fbclid", "gclid", "igsh", "igshid", "si", "mc_cid", "mc_eid",
                                             "ref_src", "ref_url"]
    /// Parameters that track the share only on that site (by host suffix).
    static let siteTrackingNames: [String: Set<String>] = ["instagram.com": ["l"]]

    /// A comparison key for `url`; the text itself if it isn't a URL with a host.
    public static func key(_ url: String) -> String {
        guard var c = URLComponents(string: url), let host = c.host?.lowercased(), !host.isEmpty else { return url }
        c.host = host
        let site = siteTrackingNames.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        if let items = c.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !trackingNames.contains(name) && !site.contains(name)
            }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        return c.string ?? url
    }

    /// `urls` with later copies of the same link dropped; order is kept.
    public static func deduplicated(_ urls: [CapturedURL]) -> [CapturedURL] {
        var seen = Set<String>()
        return urls.filter { seen.insert(key($0.url)).inserted }
    }
}
