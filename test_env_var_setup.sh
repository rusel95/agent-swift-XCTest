#!/bin/zsh

# Test script to verify environment variable setup for ReportPortal
# Run this BEFORE running your tests to set up the environment

echo "🧪 [Test] Setting up ReportPortal environment variables..."

# Generate unique UUIDs for this test run
LAUNCH_UUID=$(uuidgen)
LAUNCH_ID="$LAUNCH_UUID"  # Use same value for consistency

echo ""
echo "📋 Generated values:"
echo "   RP_LAUNCH_UUID = $LAUNCH_UUID"
echo "   RP_LAUNCH_ID   = $LAUNCH_ID"
echo ""

# Set environment variables using launchctl
# These will be available to all processes launched by Xcode
launchctl setenv RP_LAUNCH_UUID "$LAUNCH_UUID"
launchctl setenv RP_LAUNCH_ID "$LAUNCH_ID"

echo "✅ Environment variables set successfully"
echo ""
echo "🔍 Verifying values..."

# Verify the values were set
VERIFY_UUID=$(launchctl getenv RP_LAUNCH_UUID 2>/dev/null)
VERIFY_ID=$(launchctl getenv RP_LAUNCH_ID 2>/dev/null)

if [[ "$VERIFY_UUID" == "$LAUNCH_UUID" ]]; then
    echo "   ✅ RP_LAUNCH_UUID verified: $VERIFY_UUID"
else
    echo "   ❌ RP_LAUNCH_UUID verification failed!"
    echo "      Expected: $LAUNCH_UUID"
    echo "      Got: $VERIFY_UUID"
fi

if [[ "$VERIFY_ID" == "$LAUNCH_ID" ]]; then
    echo "   ✅ RP_LAUNCH_ID verified: $VERIFY_ID"
else
    echo "   ❌ RP_LAUNCH_ID verification failed!"
    echo "      Expected: $LAUNCH_ID"
    echo "      Got: $VERIFY_ID"
fi

echo ""
echo "🎯 Next steps:"
echo "   1. Run your tests from Xcode"
echo "   2. Check console output for:"
echo "      - '🌍 [ReportPortal] UUID from environment: $LAUNCH_UUID'"
echo "      - '🌍 [LAUNCH] Using launch ID from RP_LAUNCH_ID: $LAUNCH_ID'"
echo "   3. All devices should use the SAME UUID/ID"
echo ""
echo "🧹 To clean up after testing, run:"
echo "   launchctl unsetenv RP_LAUNCH_UUID"
echo "   launchctl unsetenv RP_LAUNCH_ID"
echo ""
