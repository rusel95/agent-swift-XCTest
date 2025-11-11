#!/bin/bash

# Run UI tests with filtered output showing only sync logs and errors

set -e

echo "🧪 Running UI tests with clean output..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

xcodebuild test \
  -scheme agent-swift-XCTest \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 4 \
  2>&1 | grep -E '\[SYNC\]|Test Suite .* (started|passed|failed)|Test Case .* (started|passed|failed)|ERROR|FAILED|⚠️|❌|🚀|✅|📊|🎯|🔧|🔗|📱|ℹ️|⚙️|Running tests'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Tests complete! Check output above for sync coordination."
