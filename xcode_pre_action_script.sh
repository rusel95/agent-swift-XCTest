#!/bin/zsh

# Xcode Pre-Action Test Script
# Copy this EXACTLY into Xcode → Edit Scheme → Test → Pre-actions

echo "================================================"
echo "🚀 [ReportPortal] Pre-Action Script Starting..."
echo "================================================"

# Generate unique UUIDs
LAUNCH_UUID=$(uuidgen)

echo ""
echo "📋 Generated UUID: $LAUNCH_UUID"
echo ""

# Set environment variables
launchctl setenv RP_LAUNCH_UUID "$LAUNCH_UUID"
launchctl setenv RP_LAUNCH_ID "$LAUNCH_UUID"

echo "✅ Environment variables set:"
echo "   RP_LAUNCH_UUID = $LAUNCH_UUID"
echo "   RP_LAUNCH_ID   = $LAUNCH_UUID"

# Verify
VERIFY=$(launchctl getenv RP_LAUNCH_UUID 2>/dev/null)
if [[ "$VERIFY" == "$LAUNCH_UUID" ]]; then
    echo "✅ Verification successful!"
else
    echo "❌ Verification FAILED - variable not set correctly"
fi

echo ""
echo "================================================"
echo "🎯 Pre-Action Complete - Starting Tests..."
echo "================================================"
echo ""
