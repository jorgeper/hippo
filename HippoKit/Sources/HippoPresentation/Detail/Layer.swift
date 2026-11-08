import Foundation

/// Where a shown element came from. Drawn as a coloured stripe by the App; decided here so it is tested.
public enum Layer: String, Sendable {
    case bronze, silver, gold, sync
}
