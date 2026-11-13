import Testing
@testable import HippoPresentation

@Suite struct TierVisibilityTests {
    @Test func standardShowsEveryLayerAndHidesTheLog() {
        let v = TierVisibility.standard
        #expect(v.raw && v.phone && v.server && v.sync)
        #expect(!v.log)
        #expect(v == TierVisibility())
    }

    @Test func showsMapsEachLayerToItsSwitch() {
        let cases: [(Layer, WritableKeyPath<TierVisibility, Bool>)] = [
            (.bronze, \.raw), (.silver, \.phone), (.gold, \.server), (.sync, \.sync),
        ]
        for (layer, path) in cases {
            var v = TierVisibility.standard
            #expect(v.shows(layer), "\(layer)")
            v[keyPath: path] = false
            #expect(!v.shows(layer), "\(layer)")
            // Turning one switch off hides only its own layer.
            for (other, _) in cases where other != layer { #expect(v.shows(other), "\(layer) hides \(other)") }
        }
    }

    @Test func logSwitchHidesNoLayer() {
        var v = TierVisibility.standard
        v.log = true
        for layer in [Layer.bronze, .silver, .gold, .sync] { #expect(v.shows(layer)) }
    }
}
