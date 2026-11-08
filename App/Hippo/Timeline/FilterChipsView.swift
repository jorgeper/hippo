import SwiftUI
import HippoPresentation

struct FilterChipsView: View {
    @Binding var filter: TimelineFilterState
    let onFilters: () -> Void

    private static let chips: [(QuickChip, String)] = [
        (.all, "All"), (.links, "Links"), (.images, "Images"), (.notes, "Notes"), (.audio, "Audio"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.chips, id: \.0) { chip, title in
                    chipButton(title, selected: filter.activeChip == chip) { filter = filter.select(chip) }
                }
                chipButton(filter.sheet.activeCount > 0 ? "Filters \(filter.sheet.activeCount)" : "Filters",
                           selected: filter.sheet.activeCount > 0, systemImage: "line.3.horizontal.decrease",
                           action: onFilters)
                    .accessibilityLabel(filter.sheet.activeCount > 0 ? "Filters, \(filter.sheet.activeCount) active" : "Filters")
            }
            .padding(.horizontal)
        }
    }

    private func chipButton(_ title: String, selected: Bool, systemImage: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
