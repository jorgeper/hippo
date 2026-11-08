.PHONY: generate test sim device diagnostics

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
