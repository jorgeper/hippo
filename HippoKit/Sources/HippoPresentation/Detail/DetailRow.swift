import Foundation

/// One labelled value in the details screen. Rows with no value are never built.
public struct DetailRow: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// What the large preview at the top of the details screen shows.
public enum PreviewKind: Equatable, Sendable {
    case image(URL)
    case video(URL)
    case audio(URL)
    case pdf(URL)
    /// The typed note body.
    case text(String)
    case link(URL)
    /// `previewable` is false for `public.html` and anything conforming to it: offered through Share only.
    case file(URL, previewable: Bool)
    case none
}
