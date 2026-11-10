import SwiftUI

/// The round capture control: Note and Camera in the accent colour, Record in red, a white symbol and no
/// text. 56 pt in the bars, 88 pt on the recorder sheet. Builds in the app and the Share Extension.
struct CaptureButton: View {
    enum Kind: Equatable { case note, camera, record(recording: Bool) }

    let kind: Kind
    var size: CGFloat = 56
    /// Overrides the default identifier (`note-button`, `camera-button`, `record-button`).
    var identifier: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if case .record(recording: true) = kind {
                    RoundedRectangle(cornerRadius: size * 0.09)
                        .fill(.white)
                        .frame(width: size * 0.32, height: size * 0.32)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? defaultIdentifier)
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .note, .camera: AnyShapeStyle(.tint)
        case .record: AnyShapeStyle(.red)
        }
    }

    private var symbol: String {
        switch kind {
        case .note: "square.and.pencil"
        case .camera: "camera"
        case .record: "mic"
        }
    }

    private var label: String {
        switch kind {
        case .note: "Note"
        case .camera: "Camera"
        case .record(let recording): recording ? "Stop" : "Record"
        }
    }

    private var defaultIdentifier: String {
        switch kind {
        case .note: "note-button"
        case .camera: "camera-button"
        case .record: "record-button"
        }
    }
}
