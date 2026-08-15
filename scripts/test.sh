#!/bin/bash
# Canonical test run for this package. The package is iOS-only (it imports
# UIKit), so `swift test` cannot run it — tests need an iOS simulator
# destination, which only xcodebuild provides for a bare SwiftPM package.
#
# Usage: scripts/test.sh ["platform=iOS Simulator,name=<sim name>"]
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${1:-platform=iOS Simulator,name=iPhone 17 Pro}"
log=$(mktemp)

# Never pipe xcodebuild's output straight into a filter: the filter's exit
# status would replace the build's. Capture, check, then summarize.
if ! xcodebuild test \
    -scheme LensTintSegmentedControl \
    -destination "$destination" \
    >"$log" 2>&1; then
  tail -40 "$log"
  echo "TESTS: FAIL (full log: $log)"
  exit 1
fi

grep -E "Test Suite '.*' (passed|failed)|Executed .* tests" "$log" | tail -4
echo "TESTS: PASS"
