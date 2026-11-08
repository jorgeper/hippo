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
    /// A 3 pt full-height bar just inside the cell's leading edge, by where the content came from.
    /// Drawn as the row background (normal grouped-cell colour plus the bar), so it spans the whole
    /// cell, leaves no gaps between rows and never moves the content. Apply it on each row view.
    /// With `shown` false the row keeps the system background. Decorative: `accessibilityHidden`.
    @ViewBuilder
    func layerStripe(_ layer: Layer, shown: Bool) -> some View {
        if shown {
            self.listRowBackground(
                ZStack(alignment: .leading) {
                    Color(.secondarySystemGroupedBackground)
                    layer.stripeColor.frame(width: 3).padding(.leading, 6)
                }
                .accessibilityHidden(true))
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
