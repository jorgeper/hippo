import Testing
@testable import CaptureCore

@Suite struct CircumstanceWordingTests {
    @Test func knownLabelsInWords() {
        let expected = ["in_car": "In a car", "walking": "Walking", "running": "Running", "cycling": "Cycling",
                        "on_headphones": "On headphones", "in_a_burst": "Several captures in a row",
                        "daylight": "In daylight", "dark": "After dark"]
        for (label, words) in expected { #expect(CircumstanceWording.text(for: label) == words, "\(label)") }
    }

    @Test func unknownLabelAsWritten() {
        #expect(CircumstanceWording.text(for: "on_a_boat") == "on_a_boat")
    }

    @Test func confidenceInWords() {
        #expect(CircumstanceWording.confidence("low") == "Low confidence")
        #expect(CircumstanceWording.confidence("medium") == "Medium confidence")
        #expect(CircumstanceWording.confidence("high") == "High confidence")
        #expect(CircumstanceWording.confidence("certain") == "certain")
    }
}
