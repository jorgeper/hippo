import Foundation

/// YouTube's public oEmbed endpoint: titles and thumbnails without fetching the watch page.
public enum YouTubeOEmbed {
    public static func requestURL(for videoURL: URL) -> URL {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=%")
        let encoded = videoURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json")!
    }

    public static func parse(_ data: Data) -> (title: String?, channel: String?, thumbnailURL: URL?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, nil) }
        func text(_ key: String) -> String? {
            guard let s = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return (text("title"), text("author_name"), text("thumbnail_url").flatMap { URL(string: $0) })
    }
}
