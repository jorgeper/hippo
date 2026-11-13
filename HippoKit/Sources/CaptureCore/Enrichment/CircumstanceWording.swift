import Foundation

/// Plain words for `circumstance` labels and confidences (format 1.2), for the details screen and search.
/// They read as likely, never as fact; an unknown value is returned as written.
public enum CircumstanceWording {
    private static let labels: [String: String] = [
        "in_car": "In a car", "walking": "Walking", "running": "Running", "cycling": "Cycling",
        "on_headphones": "On headphones", "in_a_burst": "Several captures in a row",
        "daylight": "In daylight", "dark": "After dark",
    ]

    private static let confidences: [String: String] = [
        "low": "Low confidence", "medium": "Medium confidence", "high": "High confidence",
    ]

    public static func text(for label: String) -> String { labels[label] ?? label }

    public static func confidence(_ value: String) -> String { confidences[value] ?? value }
}
