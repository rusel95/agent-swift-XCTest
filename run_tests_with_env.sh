#!/bin/zsh

# Run tests LOCALLY with environment variables
# This approach works from command line and uses dynamic UUIDs

echo "🚀 Running tests locally with environment variables..."
echo ""

# Generate UUID for this test run
LAUNCH_UUID=$(uuidgen)

echo "📋 Generated Launch UUID: $LAUNCH_UUID"
echo ""

# EXPORT environment variables so they're inherited by xcodebuild and test processes
export RP_LAUNCH_UUID="$LAUNCH_UUID"
export RP_LAUNCH_ID="$LAUNCH_UUID"

echo "✅ Exported environment variables:"
echo "   RP_LAUNCH_UUID = $RP_LAUNCH_UUID"
echo "   RP_LAUNCH_ID   = $RP_LAUNCH_ID"
echo ""

# Configuration
SCHEME="${1:-Example}"  # Default to "Example" scheme, or use first argument
DESTINATION="${2:-platform=iOS Simulator,name=iPhone 15}"

echo "🎯 Test Configuration:"
echo "   Scheme:      $SCHEME"
echo "   Destination: $DESTINATION"
echo ""

# Ask user to confirm or customize
echo "Press Enter to start tests, or Ctrl+C to cancel..."
read

echo "🏃 Starting tests..."
echo ""

# Run tests - environment variables will be inherited
xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -parallel-testing-enabled YES \
  | tee test_output.log

echo ""
echo "✅ Tests complete!"
echo ""
echo "🔍 Check for environment variable usage in logs:"
grep "UUID from environment" test_output.log || echo "⚠️  Environment variable NOT detected"
echo ""
