import SwiftUI
import HippoPresentation

/// Five small capsule toggles under the preview: Raw, Phone, Server, Sync and Log. On is a filled capsule with a
/// filled dot in the tier's stripe colour; off is an outline with a hollow dot. One tap toggles. When the capsules
/// don't fit on one line (large text), the row scrolls sideways instead of clipping.
struct TierSwitches: View {
    let visibility: TierVisibility
    let onChange: (TierVisibility) -> Void

    private struct Tier {
        let id: String
        let title: String
        let color: Color
        let key: WritableKeyPath<TierVisibility, Bool>
    }

    private static let tiers = [
        Tier(id: "raw", title: "Raw", color: Layer.bronze.stripeColor, key: \.raw),
        Tier(id: "phone", title: "Phone", color: Layer.silver.stripeColor, key: \.phone),
        Tier(id: "server", title: "Server", color: Layer.gold.stripeColor, key: \.server),
        Tier(id: "sync", title: "Sync", color: Layer.sync.stripeColor, key: \.sync),
        Tier(id: "log", title: "Log", color: .secondary, key: \.log),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            ForEach(Self.tiers, id: \.id) { capsule($0) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func capsule(_ tier: Tier) -> some View {
        let on = visibility[keyPath: tier.key]
        return Button {
            var next = visibility
            next[keyPath: tier.key].toggle()
            onChange(next)
        } label: {
            HStack(spacing: 4) {
                Group {
                    if on {
                        Circle().fill(tier.color)
                    } else {
                        Circle().strokeBorder(tier.color, lineWidth: 1.5)
                    }
                }
                .frame(width: 8, height: 8)
                Text(tier.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                if on {
                    Capsule().fill(Color(.tertiarySystemFill))
                } else {
                    Capsule().strokeBorder(Color(.separator), lineWidth: 1)
                }
            }
            // The capsule is small; the tap target is at least 44 pt tall.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tier.title)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint("Shows or hides this tier on every capture")
        .accessibilityIdentifier("tier-\(tier.id)")
    }
}
