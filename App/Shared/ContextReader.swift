import AVFoundation
import CaptureCore
import Foundation
import UIKit

/// Reads the platform state recorded as capture context. Every reader is passive: it never changes the
/// audio session, prompts, or throws; an unreadable field is nil.
@MainActor
enum ContextReader {
    /// The Share Extension has no key window; its view controller registers a view here so the
    /// interface style can still be read.
    static weak var traitSource: UIView?

    /// `AVAudioSession.currentRoute` as it is now. Never calls `setActive` or `setCategory`.
    static func audioRoute() -> ContextSnapshot.AudioRoute? {
        let route = AVAudioSession.sharedInstance().currentRoute
        func port(_ p: AVAudioSessionPortDescription) -> ContextSnapshot.Port {
            ContextSnapshot.Port(type: portType(p.portType), name: p.portName)
        }
        let outputs = route.outputs.map(port), inputs = route.inputs.map(port)
        if outputs.isEmpty && inputs.isEmpty { return nil }
        return ContextSnapshot.AudioRoute(outputs: outputs, inputs: inputs)
    }

    /// Starts battery monitoring early so the first `device()` read in a process has a level.
    static func startBatteryMonitoring() { UIDevice.current.isBatteryMonitoringEnabled = true }

    static func device() -> ContextSnapshot.Device {
        let ui = UIDevice.current
        // Fallback for the extension; the app enables this at launch.
        ui.isBatteryMonitoringEnabled = true
        let level = ui.batteryLevel
        let battery: String? = switch ui.batteryState {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        default: nil
        }
        let thermal: String? = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: nil
        }
        let orientation: String? = switch ui.orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portrait_upside_down"
        case .landscapeLeft: "landscape_left"
        case .landscapeRight: "landscape_right"
        case .faceUp: "face_up"
        case .faceDown: "face_down"
        default: nil
        }
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)
        return ContextSnapshot.Device(
            batteryLevel: level < 0 ? nil : Double(level),
            batteryState: battery,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: thermal,
            interfaceStyle: interfaceStyle(),
            orientation: orientation,
            locale: Locale.current.identifier,
            uses24HourClock: template.map { !$0.contains("a") })
    }

    private static func interfaceStyle() -> String? {
        var traits = traitSource?.traitCollection
        #if !HIPPO_SHARE_EXTENSION
        if traits == nil {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first
            traits = scene?.windows.first(where: \.isKeyWindow)?.traitCollection
        }
        #endif
        switch traits?.userInterfaceStyle {
        case .light: return "light"
        case .dark: return "dark"
        default: return nil
        }
    }

    static func portType(_ p: AVAudioSession.Port) -> String {
        switch p {
        case .builtInSpeaker: "built_in_speaker"
        case .builtInReceiver: "built_in_receiver"
        case .builtInMic: "built_in_mic"
        case .headphones: "headphones"
        case .headsetMic: "headset_mic"
        case .bluetoothA2DP: "bluetooth_a2dp"
        case .bluetoothHFP: "bluetooth_hfp"
        case .bluetoothLE: "bluetooth_le"
        case .carAudio: "car_audio"
        case .airPlay: "airplay"
        case .HDMI: "hdmi"
        case .usbAudio: "usb_audio"
        case .lineOut: "line_out"
        case .lineIn: "line_in"
        default: p.rawValue
        }
    }
}
