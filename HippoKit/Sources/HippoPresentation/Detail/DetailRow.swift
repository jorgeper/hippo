import Foundation

/// One labelled value in the details screen. Rows with no value are never built.
public struct DetailRow: Equatable, Sendable {
    public var label: String
    public var value: String
    public var layer: Layer

    public init(label: String, value: String, layer: Layer = .bronze) {
        self.label = label
        self.value = value
        self.layer = layer
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
    /// `name` is the original filename from the metadata; the stored file is named by its attachment ID.
    case file(URL, previewable: Bool, name: String?)
    /// A trimmed attachment: the original is only in the destination.
    case remoteOnly(RemoteOnlyAttachment)
    case none
}

/// An attachment trimmed from this iPhone: what the details screen shows in place of its file.
public struct RemoteOnlyAttachment: Equatable, Sendable {
    public var attachmentID: String
    public var relativePath: String
    public var byteCount: Int64
    /// The kept thumbnail, when one exists on disk.
    public var thumbnailURL: URL?
    /// "photo", "video" or "doc".
    public var symbol: String
    public var state: State

    public enum State: Equatable, Sendable {
        case available(destinationName: String)
        case unavailable(message: String)
        case mismatch(message: String)
    }

    public init(attachmentID: String, relativePath: String, byteCount: Int64, thumbnailURL: URL?, symbol: String,
                state: State) {
        self.attachmentID = attachmentID
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.thumbnailURL = thumbnailURL
        self.symbol = symbol
        self.state = state
    }

    /// "Connect <provider> (account <account>) to download"; without a provider name, "Connect <account> to download".
    public static func unavailableText(providerName: String?, accountName: String?) -> String {
        switch (providerName, accountName) {
        case let (provider?, account?): "Connect \(provider) (account \(account)) to download"
        case let (provider?, nil): "Connect \(provider) to download"
        case let (nil, account?): "Connect \(account) to download"
        case (nil, nil): "Connect your storage to download"
        }
    }

    public static func mismatchText(destinationName: String?) -> String {
        "Changed in \(destinationName ?? "your storage"): this file no longer matches"
    }

    public static func goneText(destinationName: String?) -> String {
        let name = destinationName ?? "your storage"
        return "This file was only in \(name) and is gone there. Restore it from Dropbox's deleted files on dropbox.com."
    }

    /// The Storage row's value.
    public var storageText: String {
        switch state {
        case .available(let name):
            "In \(name) · Download (\(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)))"
        case .unavailable(let message), .mismatch(let message): message
        }
    }
}
