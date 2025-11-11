#!/bin/zsh

# Quick test to verify environment variable inheritance
# This tests if exported variables are visible to child processes

echo "🧪 Testing environment variable inheritance..."
echo ""

# Generate test UUID
TEST_UUID=$(uuidgen)

# Export the variable
export RP_LAUNCH_UUID="$TEST_UUID"
export RP_LAUNCH_ID="$TEST_UUID"

echo "✅ Exported variables:"
echo "   RP_LAUNCH_UUID = $RP_LAUNCH_UUID"
echo "   RP_LAUNCH_ID   = $RP_LAUNCH_ID"
echo ""

# Test 1: Can this script see them?
echo "🔍 Test 1: Current shell access"
if [[ -n "$RP_LAUNCH_UUID" ]]; then
    echo "   ✅ RP_LAUNCH_UUID is visible: $RP_LAUNCH_UUID"
else
    echo "   ❌ RP_LAUNCH_UUID is NOT visible"
fi

if [[ -n "$RP_LAUNCH_ID" ]]; then
    echo "   ✅ RP_LAUNCH_ID is visible: $RP_LAUNCH_ID"
else
    echo "   ❌ RP_LAUNCH_ID is NOT visible"
fi
echo ""

# Test 2: Can a child process see them?
echo "🔍 Test 2: Child process (zsh subshell)"
zsh -c '
if [[ -n "$RP_LAUNCH_UUID" ]]; then
    echo "   ✅ Child process sees RP_LAUNCH_UUID: $RP_LAUNCH_UUID"
else
    echo "   ❌ Child process does NOT see RP_LAUNCH_UUID"
fi

if [[ -n "$RP_LAUNCH_ID" ]]; then
    echo "   ✅ Child process sees RP_LAUNCH_ID: $RP_LAUNCH_ID"
else
    echo "   ❌ Child process does NOT see RP_LAUNCH_ID"
fi
'
echo ""

# Test 3: What does Swift see?
echo "🔍 Test 3: Swift ProcessInfo (simulates test environment)"
cat > /tmp/test_env.swift << 'EOF'
import Foundation

if let uuid = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"] {
    print("   ✅ Swift sees RP_LAUNCH_UUID: \(uuid)")
} else {
    print("   ❌ Swift does NOT see RP_LAUNCH_UUID")
}

if let id = ProcessInfo.processInfo.environment["RP_LAUNCH_ID"] {
    print("   ✅ Swift sees RP_LAUNCH_ID: \(id)")
} else {
    print("   ❌ Swift does NOT see RP_LAUNCH_ID")
}
EOF

swift /tmp/test_env.swift

echo ""
echo "================================================"
echo "Summary:"
echo "If ALL tests show ✅, then 'export' works correctly"
echo "and xcodebuild will inherit the variables."
echo "================================================"
