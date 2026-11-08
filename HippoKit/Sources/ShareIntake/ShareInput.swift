import Foundation

/// What a Share Extension was handed, reduced to the parts the intake uses.
public struct ShareInput: Sendable {
    public var title: String?
    public var contentText: String?
    public var providers: [any ItemProviding]
    /// Key names only; values are never read.
    public var userInfoKeys: [String]

    public init(title: String?, contentText: String?, providers: [any ItemProviding], userInfoKeys: [String]) {
        self.title = title; self.contentText = contentText; self.providers = providers; self.userInfoKeys = userInfoKeys
    }

    /// Every item's standard `userInfo` entries; they say nothing about the sharing app.
    private static let standardKeys: Set<String> = [
        NSExtensionItemAttachmentsKey, NSExtensionItemAttributedTitleKey, NSExtensionItemAttributedContentTextKey,
    ]

    /// The first non-blank title, every non-blank content text joined by a blank line, all attachments in
    /// order, and the distinct non-standard `userInfo` key names.
    public static func from(_ items: [NSExtensionItem]) -> ShareInput {
        let titles = items.compactMap { $0.attributedTitle?.string }
        let texts = items.compactMap { $0.attributedContentText?.string }.filter { !isBlank($0) }
        var keys: [String] = []
        for item in items {
            for case let key as String in (item.userInfo ?? [:]).keys
            where !standardKeys.contains(key) && !keys.contains(key) {
                keys.append(key)
            }
        }
        return ShareInput(title: titles.first { !isBlank($0) },
                          contentText: texts.isEmpty ? nil : texts.joined(separator: "\n\n"),
                          providers: items.flatMap { $0.attachments ?? [] }.map(SystemItemProvider.init),
                          userInfoKeys: keys)
    }

    private static func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
