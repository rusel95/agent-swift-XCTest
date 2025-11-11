# Running Tests Locally with Environment Variables

Yes! You can absolutely use the command-line approach locally. Here are all the ways:

## ✅ Method 1: Quick Test Script (Recommended for Local Testing)

**Fastest way** - runs a single test suite:

```bash
./quick_test.sh

# Or specify device:
./quick_test.sh "iPhone 15 Pro"
```

**What it does:**
- Generates unique UUID
- Runs `ExampleUITests/ParallelCalculationsUITests`
- Logs to `~/Desktop/reportportal_sync.log`
- Completes in ~30 seconds

---

## ✅ Method 2: Full Test Run with Confirmation

**More control** - asks before running:

```bash
./run_tests_with_env.sh

# Or specify scheme and device:
./run_tests_with_env.sh Example "platform=iOS Simulator,name=iPhone 15 Pro"
```

**What it does:**
- Shows UUID and configuration
- Asks for confirmation (press Enter)
- Runs all tests in scheme
- Saves output to `test_output.log`

---

## ✅ Method 3: One-Liner (For Quick Testing)

**No script needed** - paste directly in terminal:

```bash
export RP_LAUNCH_UUID="$(uuidgen)" && \
export RP_LAUNCH_ID="$RP_LAUNCH_UUID" && \
echo "UUID: $RP_LAUNCH_UUID" && \
xcodebuild test \
  -scheme Example \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:ExampleUITests/ParallelCalculationsUITests
```

**Customization:**
```bash
# Change device
-destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# Run all tests (remove -only-testing)
xcodebuild test -scheme Example -destination '...'

# Run specific test
-only-testing:ExampleUITests/ParallelNavigationUITests
```

---

## ✅ Method 4: Multi-Device Parallel Testing

**Simulate CI/CD locally** - run on multiple devices at once:

```bash
# Set shared UUID
export RP_LAUNCH_UUID="$(uuidgen)"
export RP_LAUNCH_ID="$RP_LAUNCH_UUID"

echo "🚀 Shared UUID: $RP_LAUNCH_UUID"
echo ""

# Run on device 1 (background)
xcodebuild test \
  -scheme Example \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  > device1.log 2>&1 &

# Run on device 2 (background)
xcodebuild test \
  -scheme Example \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  > device2.log 2>&1 &

# Wait for both to complete
wait

echo "✅ Both devices finished!"
echo "📋 Check ~/Desktop/reportportal_sync.log for coordination timeline"
```

**Expected result:**
- Both devices use same UUID
- All tests report to same launch
- Sync log shows coordination between devices

---

## ✅ Method 5: Custom UUID (Debugging)

**Test with specific UUID** - useful for debugging a launch:

```bash
# Use a specific UUID (e.g., from ReportPortal)
export RP_LAUNCH_UUID="B60EA9AC-3C83-4D02-970C-74127CD73B0E"
export RP_LAUNCH_ID="$RP_LAUNCH_UUID"

xcodebuild test -scheme Example -destination '...'
```

**Use case:** Re-run tests against an existing launch ID for debugging

---

## Comparison: Command-Line vs Xcode UI

| Feature | Command-Line (`./quick_test.sh`) | Xcode UI (Cmd+U) |
|---------|----------------------------------|------------------|
| **Dynamic UUID** | ✅ Each run gets unique UUID | ⚠️ Uses file-based (auto-reuses) |
| **Environment Vars** | ✅ Explicit control | ⚠️ Must set in scheme |
| **Speed** | ✅ Faster startup | ⏱️ Xcode overhead |
| **Debugging** | ❌ No breakpoints | ✅ Full debugging |
| **Logs** | ✅ Clean, scriptable | ⚠️ Mixed with Xcode output |
| **CI/CD Preview** | ✅ Exact same approach | ❌ Different |

---

## Recommended Workflow

### For Development (Iterating on Code)
```bash
# Use Xcode UI - fastest iteration
Cmd+U
```
- File-based coordination works automatically
- Full debugging support
- Quick iteration

### For Testing Coordination Logic
```bash
# Use command-line - explicit control
./quick_test.sh
```
- See exact UUID being used
- Verify environment variable usage
- Test multi-device scenarios

### For CI/CD Testing Locally
```bash
# Simulate pipeline
./run_tests_with_env.sh
```
- Same approach as CI/CD
- Verify scripts work before pushing
- Test parallel execution

---

## Verifying Environment Variables Work

After running with environment variables, check the logs:

```bash
# Console output should show:
grep "UUID from environment" test_output.log

# Expected:
🌍 [ReportPortal] UUID from environment: 23187F74-B973-4FFE-890C-06ECC0B8ABB8

# Sync log should show the UUID:
grep "23187F74-B973-4FFE-890C-06ECC0B8ABB8" ~/Desktop/reportportal_sync.log
```

---

## Available Devices

List all available simulators:

```bash
xcrun simctl list devices available | grep iPhone

# Example output:
    iPhone 15 (12345678-1234-1234-1234-123456789012) (Shutdown)
    iPhone 15 Plus (12345678-1234-1234-1234-123456789013) (Shutdown)
    iPhone 15 Pro (12345678-1234-1234-1234-123456789014) (Shutdown)
    iPhone 15 Pro Max (12345678-1234-1234-1234-123456789015) (Shutdown)
```

Use any device name in the destination:
```bash
-destination 'platform=iOS Simulator,name=iPhone 15 Pro Max'
```

---

## Troubleshooting

### Issue: "No such scheme"
```bash
# Check available schemes:
xcodebuild -list -project ReportPortalAgent.xcodeproj

# Use correct scheme name:
xcodebuild test -scheme Example ...
```

### Issue: "Environment variable not detected"
```bash
# Verify export:
echo $RP_LAUNCH_UUID

# Should show UUID, not empty

# Check if tests see it:
grep "environment" test_output.log
```

### Issue: "Device not found"
```bash
# List available devices:
xcrun simctl list devices available

# Use exact name from list
```

---

## Summary

**YES!** Command-line approach works perfectly locally:

✅ **Quick testing:** `./quick_test.sh`
✅ **Full control:** `./run_tests_with_env.sh`
✅ **Custom scenarios:** One-liner with `export` + `xcodebuild`
✅ **Multi-device:** Multiple `xcodebuild` with same UUID

**Benefits locally:**
- Dynamic UUID per run (vs file-based reuse)
- Explicit control over environment
- Same approach as CI/CD
- Easy to script and automate

**When to use:**
- Testing coordination logic
- Verifying UUID usage
- Simulating CI/CD locally
- Multi-device scenarios

**When to use Xcode UI:**
- Daily development
- Debugging with breakpoints
- Quick iteration on code changes
