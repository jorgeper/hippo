import SwiftUI
import HippoPresentation

/// One log line: time (monospaced digits), a 6 pt dot in the layer's stripe colour, then the text.
struct LogLineRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Circle().fill(line.layer.stripeColor).frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                .accessibilityHidden(true)
            Text(line.text).font(.subheadline)
        }
    }
}

/// Toolbar "Copy": writes `text()` to the pasteboard and shows "Copied" for a moment.
struct CopyLogButton: View {
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy") {
            UIPasteboard.general.string = text()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .accessibilityIdentifier("log-copy")
    }
}

func hippoAppVersion() -> String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "\(info["CFBundleShortVersionString"] as? String ?? "0") (\(info["CFBundleVersion"] as? String ?? "0"))"
}
