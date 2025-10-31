# Quickstart Guide: Parallel Launch Coordination

**Feature**: 002-parallel-launch-coordination
**Target Audience**: iOS developers using ReportPortal agent for parallel test execution
**Time to Setup**: ~5 minutes

---

## Overview

This guide shows you how to enable parallel test coordination so that all your simulator workers report to a single unified Launch in ReportPortal instead of creating separate reports.

**What You'll Achieve**:
- ✅ Single unified Launch for all parallel test workers
- ✅ Zero-configuration Xcode integration
- ✅ Proper test result aggregation across workers
- ✅ Automatic coordination without external scripts

---

## Prerequisites

- Xcode 13.0+ with parallel testing enabled
- iOS 15.0+ or macOS 12.0+ target
- ReportPortal agent integrated in your test target
- ReportPortal server with v2 API support (ReportPortal 5.0+)

---

## Quick Setup (Zero Configuration)

### Step 1: Enable Parallel Testing in Xcode

1. Open your test scheme (Product > Scheme > Edit Scheme...)
2. Select "Test" in the left sidebar
3. Go to "Options" tab
4. Check **"Execute in parallel"**
5. Set **"Maximum concurrent test runners"** (e.g., 5)

That's it! The ReportPortal agent will automatically detect parallel execution and coordinate across workers.

### Step 2: Run Your Tests

```bash
# From Xcode: Press Cmd+U (or Product > Test)

# From command line:
xcodebuild test \
  -project YourApp.xcodeproj \
  -scheme YourScheme \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 5
```

### Step 3: Verify Single Launch in ReportPortal

Navigate to ReportPortal and verify:
- ✅ Only **one Launch** appears (not multiple)
- ✅ All test results from all workers are present
- ✅ Launch status correctly reflects aggregated results

---

## Advanced Configuration (Optional)

### Option 1: Set Worker Count Explicitly

For deterministic behavior (recommended for CI/CD), set the expected worker count:

**In Xcode**:
1. Edit Scheme > Test > Arguments
2. Add Environment Variable:
   - **Name**: `RP_PARALLEL_WORKERS`
   - **Value**: `5` (number of workers)

**In CI/CD** (e.g., GitHub Actions):
```yaml
- name: Run Tests
  run: |
    xcodebuild test \
      -project YourApp.xcodeproj \
      -scheme YourScheme \
      -destination 'platform=iOS Simulator,name=iPhone 15' \
      -parallel-testing-enabled YES \
      -maximum-parallel-testing-workers 5
  env:
    RP_PARALLEL_WORKERS: 5
```

**Benefits**:
- Faster coordination (no timeout-based detection)
- Deterministic behavior across test runs
- Immediate finalization when all workers complete

### Option 2: Use Session ID for Multiple Test Runs

When running multiple parallel test sessions simultaneously, use session IDs to isolate coordination:

**In Xcode**:
1. Edit Scheme > Test > Arguments
2. Add Environment Variable:
   - **Name**: `RP_SESSION_ID`
   - **Value**: `test-run-$(date +%s)` or unique identifier

**In CI/CD**:
```bash
export RP_SESSION_ID="ci-run-${GITHUB_RUN_ID}"
xcodebuild test ...
```

**Benefits**:
- Multiple test runs can execute simultaneously without interference
- Easier debugging (coordination files named with session ID)
- Automatic cleanup isolation

### Option 3: Pre-Created Launch (Advanced)

For advanced scenarios, pre-create the Launch and pass its ID:

```bash
# Step 1: Create Launch via API
LAUNCH_ID=$(curl -X POST "https://reportportal.io/api/v2/project/launch" \
  -H "Authorization: Bearer $RP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "iOS Parallel Tests",
    "startTime": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
    "mode": "DEFAULT"
  }' | jq -r '.id')

# Step 2: Run tests with pre-created Launch ID
export RP_LAUNCH_ID=$LAUNCH_ID
xcodebuild test ...
```

**Use Cases**:
- Complex CI/CD pipelines with custom Launch names
- Merging results from multiple test sessions
- Custom Launch metadata/attributes

---

## Verification & Debugging

### Check Coordination Status

**View Coordination Logs**:
```bash
# Console logs (stdout)
# Look for messages like:
# 📌 PRIMARY LAUNCH: Obtained main lock
# 📖 SECONDARY LAUNCH: Main lock already held
# ✅ Launch ID written to coordination file

# File-based event log (detailed debugging)
cat /tmp/reportportal_coordination/events_*.log | jq '.'
```

**Expected Output**:
```json
{"timestamp":"2025-01-30T10:30:45Z","type":"Launch","event":"PRIMARY_LOCK_ACQUIRED","workerID":"worker-1"}
{"timestamp":"2025-01-30T10:30:46Z","type":"Launch","event":"LAUNCH_CREATED","launchID":"uuid-123"}
{"timestamp":"2025-01-30T10:30:47Z","type":"Launch","event":"SECONDARY_JOINED","workerID":"worker-2"}
```

### Verify Coordination Files

```bash
# List coordination files
ls -lh /tmp/reportportal_coordination/

# Expected files:
# launch_YourLaunchName_session.lock   (lock file)
# launch_YourLaunchName_session.sync   (Launch ID storage)
# events_12345.log                     (event log)
```

### Common Issues

#### Issue: Multiple Launches Created

**Symptom**: You see 5 separate Launches instead of 1 in ReportPortal

**Causes & Solutions**:
1. **Parallel testing not enabled in Xcode**
   - Fix: Enable "Execute in parallel" in test scheme options

2. **Workers starting on different machines**
   - Coordination only works on single machine (simulators share `/tmp`)
   - Fix: Use sequential mode or pre-created Launch ID

3. **ReportPortal server doesn't support v2 API**
   - Fix: Upgrade ReportPortal server to 5.0+

4. **File permission issues**
   - Check: `ls -ld /tmp/reportportal_coordination/`
   - Fix: Ensure directory is writable

#### Issue: Launch Never Finishes

**Symptom**: Launch remains "Running" in ReportPortal indefinitely

**Causes & Solutions**:
1. **Worker crashed mid-execution**
   - Check: Look for crash logs in Xcode or Console.app
   - Workaround: Set `RP_PARALLEL_WORKERS` to expected count

2. **Timeout-based detection waiting for more workers**
   - Fix: Set `RP_PARALLEL_WORKERS` environment variable

3. **Last worker failed to finalize**
   - Check: Look for errors in console logs
   - Workaround: Manually finish Launch via ReportPortal API

#### Issue: Slow Coordination

**Symptom**: Test execution delayed by 30+ seconds at start

**Cause**: Timeout-based worker count detection

**Solution**: Set `RP_PARALLEL_WORKERS` environment variable to skip timeout

---

## Architecture Overview

For developers who want to understand how it works:

```
┌─────────────────────────────────────────────────────┐
│              Xcode Parallel Testing                  │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐   │
│  │Worker 1│  │Worker 2│  │Worker 3│  │Worker 4│   │
│  └───┬────┘  └───┬────┘  └───┬────┘  └───┬────┘   │
└──────┼───────────┼───────────┼───────────┼─────────┘
       │           │           │           │
       │           │           │           │
       ▼           ▼           ▼           ▼
┌─────────────────────────────────────────────────────┐
│    Coordination Layer (/tmp/reportportal_coordination/)│
│  ┌─────────────────────────────────────────────┐   │
│  │  .lock file (POSIX flock)                   │   │
│  │  .sync file (Launch ID storage)             │   │
│  │  events.log (Coordination events)           │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
                        │
                        │ Primary creates Launch
                        │ All workers report results
                        ▼
              ┌──────────────────────┐
              │  ReportPortal Server │
              │  ┌─────────────────┐ │
              │  │  Single Launch  │ │
              │  │  (All Results)  │ │
              │  └─────────────────┘ │
              └──────────────────────┘
```

**Key Components**:
1. **LaunchCoordinator** (actor) - File-based coordination across processes
2. **LaunchManager** (actor) - Single-process launch state management
3. **LaunchIdLock** (actor) - POSIX file locking implementation
4. **FileLogger** - Coordination event logging for debugging

---

## Platform Support

### ✅ Supported: iOS Simulators (Parallel Mode)

| Platform | Mode | Workers | Coordination | Status |
|----------|------|---------|--------------|--------|
| iOS Simulator | Parallel | 2-20 | File-based | ✅ Fully supported |
| iOS Simulator | Sequential | 1 | None (not needed) | ✅ Fully supported |

**Why**: Simulators share host Mac's `/tmp` directory, enabling file-based coordination.

### ✅ Supported: Real Devices (Sequential Mode Only)

| Platform | Mode | Workers | Coordination | Status |
|----------|------|---------|--------------|--------|
| Real Device | Sequential | 1 | None (not needed) | ✅ Fully supported |
| Real Device | Parallel | 2+ | ❌ Not available | ⚠️ See workaround below |

**Why**: Real devices have isolated sandboxes with no shared file system.

### ⚠️ Real Device Parallel Workaround

If you need parallel testing on real devices, use external coordination:

```bash
# Step 1: Pre-create Launch
LAUNCH_ID=$(curl -X POST "https://reportportal.io/api/v2/project/launch" ...)

# Step 2: Set environment variable for all devices
export RP_LAUNCH_ID=$LAUNCH_ID

# Step 3: Run tests on multiple devices
xcodebuild test -destination 'id=device-1-udid' &
xcodebuild test -destination 'id=device-2-udid' &
wait

# Step 4: Finalize Launch
curl -X PUT "https://reportportal.io/api/v2/project/launch/$LAUNCH_ID/finish" ...
```

---

## CI/CD Integration Examples

### GitHub Actions

```yaml
name: iOS Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3

      - name: Run Parallel Tests
        run: |
          xcodebuild test \
            -project YourApp.xcodeproj \
            -scheme YourScheme \
            -destination 'platform=iOS Simulator,name=iPhone 15' \
            -parallel-testing-enabled YES \
            -maximum-parallel-testing-workers 5 \
            -resultBundlePath TestResults.xcresult
        env:
          RP_ENDPOINT: ${{ secrets.RP_ENDPOINT }}
          RP_TOKEN: ${{ secrets.RP_TOKEN }}
          RP_PROJECT: ${{ secrets.RP_PROJECT }}
          RP_PARALLEL_WORKERS: 5
          RP_SESSION_ID: ci-run-${{ github.run_id }}

      - name: Upload Test Results
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: test-results
          path: TestResults.xcresult
```

### GitLab CI

```yaml
test:ios:
  stage: test
  tags:
    - macos
  script:
    - export RP_SESSION_ID="ci-run-${CI_PIPELINE_ID}"
    - export RP_PARALLEL_WORKERS=5
    - xcodebuild test
        -project YourApp.xcodeproj
        -scheme YourScheme
        -destination 'platform=iOS Simulator,name=iPhone 15'
        -parallel-testing-enabled YES
        -maximum-parallel-testing-workers 5
  variables:
    RP_ENDPOINT: $RP_ENDPOINT
    RP_TOKEN: $RP_TOKEN
    RP_PROJECT: $RP_PROJECT
```

### Jenkins

```groovy
pipeline {
    agent { label 'macos' }
    environment {
        RP_SESSION_ID = "ci-run-${BUILD_ID}"
        RP_PARALLEL_WORKERS = '5'
    }
    stages {
        stage('Test') {
            steps {
                sh '''
                    xcodebuild test \
                      -project YourApp.xcodeproj \
                      -scheme YourScheme \
                      -destination 'platform=iOS Simulator,name=iPhone 15' \
                      -parallel-testing-enabled YES \
                      -maximum-parallel-testing-workers 5
                '''
            }
        }
    }
}
```

---

## Troubleshooting Commands

```bash
# Check if parallel testing is enabled
xcodebuild test -showBuildSettings | grep -i parallel

# List active simulators
xcrun simctl list devices | grep Booted

# View coordination files in real-time
watch -n 1 'ls -lh /tmp/reportportal_coordination/'

# Monitor coordination events
tail -f /tmp/reportportal_coordination/events_*.log | jq '.'

# Check ReportPortal connectivity
curl -H "Authorization: Bearer $RP_TOKEN" \
  "$RP_ENDPOINT/api/v2/$RP_PROJECT/launch?limit=10"

# Clean up stale coordination files
rm -rf /tmp/reportportal_coordination/*.lock
rm -rf /tmp/reportportal_coordination/*.sync

# Force finish a stuck Launch (replace LAUNCH_ID)
curl -X PUT "$RP_ENDPOINT/api/v1/$RP_PROJECT/launch/LAUNCH_ID/stop" \
  -H "Authorization: Bearer $RP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"endTime": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}'
```

---

## Next Steps

1. **Test with 2 workers** first to validate coordination works
2. **Scale up to 5+ workers** for production use
3. **Set `RP_PARALLEL_WORKERS`** in CI/CD for deterministic behavior
4. **Monitor coordination logs** during first few runs
5. **Read data-model.md** for deeper understanding of coordination mechanism

---

## Getting Help

- **Documentation**: See [spec.md](./spec.md) for detailed feature specification
- **Architecture**: See [data-model.md](./data-model.md) for entity definitions
- **API Contracts**: See [contracts/](./contracts/) for ReportPortal API details
- **Research**: See [research.md](./research.md) for technical decision rationale

---

**Happy Parallel Testing!** 🚀
