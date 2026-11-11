import Foundation

/// Plain values read when a capture begins. Platform readers fill this in; `ContextObservations` maps it to JSON.
public struct ContextSnapshot: Sendable, Equatable {
    public struct Port: Sendable, Equatable {
        public var type: String
        public var name: String?
        public init(type: String, name: String? = nil) { self.type = type; self.name = name }
    }
    public struct AudioRoute: Sendable, Equatable {
        public var outputs: [Port]
        public var inputs: [Port]
        public init(outputs: [Port] = [], inputs: [Port] = []) { self.outputs = outputs; self.inputs = inputs }
    }
    public struct Device: Sendable, Equatable {
        public var batteryLevel: Double?          // 0...1
        public var batteryState: String?          // unplugged | charging | full
        public var lowPowerMode: Bool?
        public var thermalState: String?          // nominal | fair | serious | critical
        public var interfaceStyle: String?        // light | dark
        public var orientation: String?           // portrait | portrait_upside_down | landscape_left | landscape_right | face_up | face_down
        public var locale: String?
        public var uses24HourClock: Bool?
        public init(batteryLevel: Double? = nil, batteryState: String? = nil, lowPowerMode: Bool? = nil,
                    thermalState: String? = nil, interfaceStyle: String? = nil, orientation: String? = nil,
                    locale: String? = nil, uses24HourClock: Bool? = nil) {
            self.batteryLevel = batteryLevel; self.batteryState = batteryState; self.lowPowerMode = lowPowerMode
            self.thermalState = thermalState; self.interfaceStyle = interfaceStyle; self.orientation = orientation
            self.locale = locale; self.uses24HourClock = uses24HourClock
        }
    }
    public struct Network: Sendable, Equatable {
        public var interface: String              // wifi | cellular | wired | other | none
        public var expensive: Bool
        public var constrained: Bool
        public init(interface: String, expensive: Bool, constrained: Bool) {
            self.interface = interface; self.expensive = expensive; self.constrained = constrained
        }
    }

    public var takenAt: Date
    public var audioRoute: AudioRoute?
    public var device: Device?
    public var network: Network?
    public init(takenAt: Date, audioRoute: AudioRoute? = nil, device: Device? = nil, network: Network? = nil) {
        self.takenAt = takenAt; self.audioRoute = audioRoute; self.device = device; self.network = network
    }
}

/// The capture saved most recently on this phone, kept in the App Group defaults.
public struct LastSaved: Codable, Sendable, Equatable {
    public var captureID: String
    public var capturedAt: Date
    public init(captureID: String, capturedAt: Date) { self.captureID = captureID; self.capturedAt = capturedAt }
}
