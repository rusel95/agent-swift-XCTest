#!/bin/zsh

# Cleanup script to remove ReportPortal environment variables

echo "🧹 [Cleanup] Removing ReportPortal environment variables..."

# Check if variables exist before removing
UUID_BEFORE=$(launchctl getenv RP_LAUNCH_UUID 2>/dev/null)
ID_BEFORE=$(launchctl getenv RP_LAUNCH_ID 2>/dev/null)

if [[ -n "$UUID_BEFORE" ]]; then
    echo "   Found RP_LAUNCH_UUID: $UUID_BEFORE"
    launchctl unsetenv RP_LAUNCH_UUID
    echo "   ✅ Removed RP_LAUNCH_UUID"
else
    echo "   ℹ️  RP_LAUNCH_UUID was not set"
fi

if [[ -n "$ID_BEFORE" ]]; then
    echo "   Found RP_LAUNCH_ID: $ID_BEFORE"
    launchctl unsetenv RP_LAUNCH_ID
    echo "   ✅ Removed RP_LAUNCH_ID"
else
    echo "   ℹ️  RP_LAUNCH_ID was not set"
fi

echo ""
echo "🔍 Verifying cleanup..."

UUID_AFTER=$(launchctl getenv RP_LAUNCH_UUID 2>/dev/null)
ID_AFTER=$(launchctl getenv RP_LAUNCH_ID 2>/dev/null)

if [[ -z "$UUID_AFTER" ]] && [[ -z "$ID_AFTER" ]]; then
    echo "   ✅ All environment variables removed successfully"
else
    echo "   ⚠️  Some variables still exist:"
    [[ -n "$UUID_AFTER" ]] && echo "      RP_LAUNCH_UUID = $UUID_AFTER"
    [[ -n "$ID_AFTER" ]] && echo "      RP_LAUNCH_ID = $ID_AFTER"
fi

echo ""
echo "✨ Cleanup complete!"
echo ""
