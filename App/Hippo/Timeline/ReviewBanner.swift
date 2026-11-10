import SwiftUI

/// "<name> looks different": a tappable row above the timeline that opens the review sheet.
struct ReviewBanner: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
                Text("\(name) looks different").font(.subheadline)
                Spacer(minLength: 8)
                Text("Review").font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("review-banner")
    }
}
