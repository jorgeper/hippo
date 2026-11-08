import Foundation
import CaptureCore

extension JSONValue {
    /// A facet payload as generic JSON (`EnricherOutput.data`).
    static func payload<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
