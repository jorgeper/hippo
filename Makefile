.PHONY: generate test uitest sim device diagnostics

# Generate Hippo.xcodeproj from project.yml (not committed).
generate:
	xcodegen generate

# HippoKit unit tests on the Mac.
test:
	swift test --package-path HippoKit

# Build, install and launch in the iOS Simulator with the fixture captures.
sim:
	scripts/sim-run.sh --seed

# Build and install on a connected iPhone (needs Config/Local.xcconfig).
device:
	scripts/install-device.sh

# Print diagnostics.json from the app on a connected iPhone.
diagnostics:
	scripts/pull-diagnostics.sh

# UI smoke tests in the iOS Simulator.
uitest:
	xcodegen generate
	xcrun simctl boot '$(or $(HIPPO_SIM),iPhone 18 Pro)' || true
	xcrun simctl privacy '$(or $(HIPPO_SIM),iPhone 18 Pro)' grant microphone com.jorgeper.hippo || true
	xcodebuild test -project Hippo.xcodeproj -scheme Hippo -destination 'platform=iOS Simulator,name=$(or $(HIPPO_SIM),iPhone 18 Pro)' -derivedDataPath build/DerivedData TEST_RUNNER_HIPPO_UITEST_MIC_GRANTED=1
