import SwiftUI
import HippoPresentation

extension Layer {
    /// Asset-catalog colour with light and dark variants.
    var stripeColor: Color {
        switch self {
        case .bronze: Color("StripeBronze")
        case .silver: Color("StripeSilver")
        case .gold: Color("StripeGold")
        case .sync: Color("StripeSync")
        }
    }
}

extension View {
    /// A 3 pt full-height bar inset at the cell's leading edge, by where the content came from.
    /// Decorative: every fact it marks is also stated in words (Status).
    @ViewBuilder
    func layerStripe(_ layer: Layer, shown: Bool) -> some View {
        if shown {
            self
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(layer.stripeColor)
                        .frame(width: 3)
                        .accessibilityHidden(true)
                }
        } else {
            self
        }
    }
}

/// A pending line: a spinner while working, plain secondary text while waiting.
struct PendingLineView: View {
    let line: PendingLine

    var body: some View {
        HStack(spacing: 8) {
            if line.working { ProgressView().controlSize(.small) }
            Text(line.text).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
