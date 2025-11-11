#!/bin/zsh

# Quick local test run with environment variables
# Usage: ./quick_test.sh [device_name]

# Generate dynamic UUID
export RP_LAUNCH_UUID="$(uuidgen)"
export RP_LAUNCH_ID="$RP_LAUNCH_UUID"

# Device selection
DEVICE="${1:-iPhone 15}"

echo "🚀 Quick Test"
echo "   UUID: $RP_LAUNCH_UUID"
echo "   Device: $DEVICE"
echo ""

# Run tests immediately (no confirmation)
xcodebuild test \
  -scheme Example \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -parallel-testing-enabled YES \
  -only-testing:ExampleUITests/ParallelCalculationsUITests

echo ""
echo "✅ Done! Check ~/Desktop/reportportal_sync.log for synchronization logs"
