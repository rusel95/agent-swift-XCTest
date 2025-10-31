# Multi-Worker Coordination for Parallel Test Execution

## Overview

When running tests in parallel (multiple devices/workers), XCTest spawns separate worker processes. Each process has isolated memory, so traditional singleton patterns don't work for coordination. This document explains how ReportPortal Agent coordinates Launch and Suite creation across multiple workers.

## Problem

**Without coordination:**
```
xcodebuild test -destination 'iPhone 16' -destination 'iPhone 15' -destination 'iPad Pro'

Worker 1 (iPhone 16) → LaunchManager.shared → Launch ID: xxx-111
Worker 2 (iPhone 15) → LaunchManager.shared → Launch ID: xxx-222
Worker 3 (iPad Pro)  → LaunchManager.shared → Launch ID: xxx-333

Result: 3 separate launches in ReportPortal ❌
```

**With coordination:**
```
xcodebuild test -destination 'iPhone 16' -destination 'iPhone 15' -destination 'iPad Pro'

Worker 1 (iPhone 16) → Creates Launch → Writes ID to file
Worker 2 (iPhone 15) → Reads Launch ID from file → Uses same Launch
Worker 3 (iPad Pro)  → Reads Launch ID from file → Uses same Launch

Result: 1 unified launch with all tests ✅
```

## Architecture

### Launch Coordination

**File Location:** `/tmp/reportportal_coordination/launch_{name}_{timestamp}.lock`

**Priority:**
1. **Environment Variable** (`RP_LAUNCH_ID`) - Pre-created by CI/CD
2. **File Coordination** - First worker creates, others read
3. **Fallback** - Each worker creates own (legacy behavior)

**Timestamp-Based Coordination:**
- ⏰ **Timestamp rounded to minute** (e.g., `2025-10-29_16-38`)
- **Why it works:** All devices in same test run start within **same minute**
- **Example:** 5 devices starting at 16:38:12 all use `launch_Demo_2025-10-29_16-38.lock`
- **Automatic cleanup:** Files older than 1 hour are deleted

**Key Design:**
```
16:38:12 - Device 1 starts → creates launch_Demo_2025-10-29_16-38.lock
16:38:13 - Device 2 starts → reads from launch_Demo_2025-10-29_16-38.lock ✅
16:38:14 - Device 3 starts → reads from launch_Demo_2025-10-29_16-38.lock ✅
16:38:15 - Device 4 starts → reads from launch_Demo_2025-10-29_16-38.lock ✅
16:38:16 - Device 5 starts → reads from launch_Demo_2025-10-29_16-38.lock ✅

Result: All 5 devices share same Launch ID! 🎯
```

### Suite Coordination

**File Location:** `/tmp/reportportal_coordination/suite_{name}_{timestamp}.lock`

**Why needed:**
XCTest can split one suite across multiple devices:

```
ParallelNavigationUITests (20 tests total)
├─ Device 1: tests 1-10
└─ Device 2: tests 11-20
```

Without coordination → 2 separate suites in ReportPortal ❌  
With coordination → 1 suite with all 20 tests ✅

**Priority:**
1. **Environment Variable** (`RP_SUITE_ID_{SuiteName}`) - Pre-created by CI/CD
2. **File Coordination** - First worker creates, others read

## Local Usage

### Automatic (No Configuration)

```bash
# Just run tests - coordination happens automatically
xcodebuild test \
  -scheme Example \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -parallel-testing-enabled YES
```

**How it works:**
1. Worker 1 starts first → Creates `/tmp/reportportal_coordination/launch_Demo_Launch_12345.lock`
2. Worker 2 starts → Reads Launch ID from file
3. Both report to same Launch in ReportPortal

### Pre-created Launch (Optional)

```bash
# Create Launch with custom metadata
LAUNCH_ID=$(curl -X POST https://reportportal.example.com/api/v1/project/launch \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Local Development Run",
    "description": "Testing new feature",
    "attributes": [
      {"key": "developer", "value": "john.doe"},
      {"key": "branch", "value": "feature/new-ui"}
    ]
  }' | jq -r '.id')

# Pass to tests
export RP_LAUNCH_ID=$LAUNCH_ID

xcodebuild test -scheme Example -destination 'iPhone 16'
```

## CI/CD Usage

### Option 1: Automatic File Coordination (Simplest)

```yaml
# .github/workflows/test.yml
- name: Run Tests
  run: |
    xcodebuild test \
      -scheme Example \
      -destination 'platform=iOS Simulator,name=iPhone 16' \
      -destination 'platform=iOS Simulator,name=iPhone 15' \
      -parallel-testing-enabled YES
```

✅ **Pros:** No configuration needed  
⚠️ **Cons:** Launch name is generic, no custom metadata

### Option 2: Pre-created Launch (Recommended)

```yaml
# .github/workflows/test.yml
- name: Create ReportPortal Launch
  id: create_launch
  run: |
    LAUNCH_ID=$(curl -X POST ${{ secrets.RP_URL }}/api/v1/${{ secrets.RP_PROJECT }}/launch \
      -H "Authorization: Bearer ${{ secrets.RP_TOKEN }}" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "CI Build #${{ github.run_number }}",
        "description": "${{ github.event.head_commit.message }}",
        "attributes": [
          {"key": "ci", "value": "github-actions"},
          {"key": "branch", "value": "${{ github.ref_name }}"},
          {"key": "commit", "value": "${{ github.sha }}"},
          {"key": "pr", "value": "${{ github.event.pull_request.number }}"}
        ]
      }' | jq -r '.id')
    echo "launch_id=$LAUNCH_ID" >> $GITHUB_OUTPUT

- name: Run Tests
  env:
    RP_LAUNCH_ID: ${{ steps.create_launch.outputs.launch_id }}
  run: |
    xcodebuild test \
      -scheme Example \
      -destination 'platform=iOS Simulator,name=iPhone 16' \
      -destination 'platform=iOS Simulator,name=iPhone 15' \
      -parallel-testing-enabled YES
```

✅ **Pros:** 
- Custom launch name with build number
- Rich metadata (PR, commit, branch)
- Launch created before tests (better UX in ReportPortal)

### Option 3: Pre-created Launch + Suites (Advanced)

```yaml
- name: Create Launch and Suites
  id: create_launch
  run: |
    # Create Launch
    LAUNCH_ID=$(curl -X POST $RP_URL/api/v1/$RP_PROJECT/launch ...)
    echo "launch_id=$LAUNCH_ID" >> $GITHUB_OUTPUT
    
    # Pre-create Suites for known test classes
    SUITE1=$(curl -X POST $RP_URL/api/v1/$RP_PROJECT/item \
      -d '{"name":"ParallelNavigationUITests","launchUuid":"'$LAUNCH_ID'","type":"suite"}' \
      | jq -r '.id')
    
    SUITE2=$(curl -X POST $RP_URL/api/v1/$RP_PROJECT/item \
      -d '{"name":"ParallelDataEntryUITests","launchUuid":"'$LAUNCH_ID'","type":"suite"}' \
      | jq -r '.id')
    
    echo "suite_navigation=$SUITE1" >> $GITHUB_OUTPUT
    echo "suite_dataentry=$SUITE2" >> $GITHUB_OUTPUT

- name: Run Tests
  env:
    RP_LAUNCH_ID: ${{ steps.create_launch.outputs.launch_id }}
    RP_SUITE_ID_ParallelNavigationUITests: ${{ steps.create_launch.outputs.suite_navigation }}
    RP_SUITE_ID_ParallelDataEntryUITests: ${{ steps.create_launch.outputs.suite_dataentry }}
  run: |
    xcodebuild test -scheme Example ...
```

✅ **Pros:** 
- Full control over structure
- Can add suite-level metadata
- Predictable Suite IDs

⚠️ **Cons:** 
- More complex setup
- Need to know suite names in advance

## How It Works Internally

### Launch Coordination Flow

```swift
// In RPListener.testBundleWillStart()
let launchID = try await launchCoordinator.getOrCreateLaunchID(
    launchName: "Demo_Launch",
    createBlock: {
        // Only executed if Launch doesn't exist
        return try await reportingService.startLaunch(...)
    }
)
```

**LaunchCoordinator Logic:**
```
1. Check environment variable RP_LAUNCH_ID
   ✓ Found → Return immediately
   ✗ Not found → Continue to step 2

2. Get PGID (Process Group ID) = 12345
   
3. Create file path: /tmp/reportportal_coordination/launch_Demo_Launch_12345.lock

4. Acquire file lock (NSFileCoordinator)

5. Try to read file
   ✓ File exists with content → Return Launch ID from file
   ✗ File empty/missing → Continue to step 6

6. Call createBlock() → Create Launch in ReportPortal

7. Write Launch ID to file

8. Release file lock

9. Return Launch ID
```

### Suite Coordination Flow

Same as Launch, but:
- Different file: `suite_{name}_{pgid}.lock`
- Environment variable: `RP_SUITE_ID_{SuiteName}`

### File Locking

Uses `NSFileCoordinator` for atomic file operations:
- **Writer 1** acquires lock → creates Launch → writes ID → releases lock
- **Writer 2** waits for lock → reads existing ID → returns immediately

Prevents race conditions when multiple workers start simultaneously.

## Troubleshooting

### Multiple Launches Still Created

**Symptom:** Seeing separate launches for each device

**Possible causes:**
1. Workers running in different process groups (shouldn't happen with single xcodebuild)
2. File coordination directory not accessible
3. Timing issue (workers not reading file)

**Debug:**
```bash
# Check coordination files
ls -la /tmp/reportportal_coordination/

# Expected: One file per test run
# launch_Demo_Launch_12345.lock

# Check PGID from test logs
# All workers should have same PGID in filename
```

### Suites Duplicated

**Symptom:** Same suite appears twice in ReportPortal

**Cause:** Suite name mismatch between workers

**Fix:** Ensure all workers use exact same suite name (case-sensitive)

### Permission Errors

**Symptom:** `Failed to create coordination directory`

**Cause:** `/tmp` not writable (rare)

**Fix:**
```bash
# Check permissions
ls -ld /tmp

# Should be: drwxrwxrwt (sticky bit set)
```

### Stale Lock Files

**Symptom:** Old lock files remain after tests

**Fix:** Automatic cleanup happens in `testBundleDidFinish`, but can manually clean:
```bash
rm -rf /tmp/reportportal_coordination/
```

## Testing Coordination

### Verify Single Launch

```bash
# Run with 2 workers
xcodebuild test \
  -scheme Example \
  -destination 'iPhone 16' \
  -destination 'iPhone 15' \
  -parallel-testing-enabled YES \
  2>&1 | grep "Launch created\|Using existing Launch"

# Expected output:
# Worker 1: 📌 Creating new Launch (first worker)
# Worker 2: 📌 Using existing Launch ID from file
```

### Verify Single Suite

```bash
# Check suite creation logs
2>&1 | grep "Suite.*ParallelNavigationUITests"

# Expected: Only one "Creating new Suite"
# All other workers: "Using existing Suite ID from file"
```

### Verify File Contents

```bash
# During test run
cat /tmp/reportportal_coordination/launch_*.lock
# Output: uuid-123-456-789 (Launch ID)

cat /tmp/reportportal_coordination/suite_*.lock
# Output: uuid-abc-def-ghi (Suite ID)
```

## Performance Impact

**File Operations:**
- File read: ~1-2ms
- File write: ~5-10ms
- NSFileCoordinator overhead: ~5ms

**Total Impact:**
- First worker: +10-15ms (creates Launch/Suite)
- Other workers: +5-10ms (reads from file)

**Comparison to creating duplicate launches:**
- Without coordination: 3 devices × 500ms API call = 1500ms wasted
- With coordination: 10ms file coordination
- **Net savings: ~1490ms** + cleaner reports

## Best Practices

1. **Use Pre-created Launch on CI/CD** - Better metadata and UX
2. **Let file coordination handle local runs** - Zero configuration
3. **Clean up stale files periodically** - Prevents clutter in `/tmp`
4. **Monitor coordination logs** - Verify workers are sharing Launch/Suites
5. **Keep suite names consistent** - Case-sensitive matching required

## Security Considerations

**File Permissions:**
- Coordination files stored in `/tmp` (world-writable with sticky bit)
- Launch/Suite IDs are UUIDs (not sensitive data)
- File names include PGID (prevents cross-run interference)

**Network Security:**
- Pre-created Launch approach requires ReportPortal token in CI/CD
- Use secrets management (GitHub Secrets, etc.)
- Never commit tokens to repository

## Future Improvements

- [ ] Add Redis/external cache option for distributed CI runners
- [ ] Support custom coordination directory via environment variable
- [ ] Add coordination statistics (file hits/misses) to logs
- [ ] Auto-detect stale files and clean up
- [ ] Support hierarchical suite coordination (nested suites)
