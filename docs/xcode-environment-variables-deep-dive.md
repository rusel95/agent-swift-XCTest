# Passing Environment Variables to Xcode Tests - Community Solutions

## The Problem

Xcode test processes run in isolated simulator environments, making it challenging to pass dynamic values (like UUIDs) from the host machine to test processes.

## Community Solutions (Ranked by Reliability)

### ✅ Solution 1: Xcode Scheme Environment Variables (STATIC VALUES ONLY)

**How it works:**
- Set environment variables directly in the Xcode scheme
- Variables are passed to test processes automatically
- **Limitation:** Values are STATIC - no dynamic generation

**How to configure:**

1. In Xcode: **Product → Scheme → Edit Scheme...**
2. Select **Test** in left sidebar
3. Go to **Arguments** tab
4. Add environment variables in **Environment Variables** section:
   ```
   Key: RP_LAUNCH_UUID
   Value: <PASTE_UUID_HERE>  (e.g., B60EA9AC-3C83-4D02-970C-74127CD73B0E)
   ```

**Pros:**
- ✅ Works reliably for Xcode UI and command-line `xcodebuild`
- ✅ Simple to configure
- ✅ Committed to repo (shared schemes)

**Cons:**
- ❌ **STATIC** - can't generate unique UUID per test run
- ❌ Must manually update value for each run
- ❌ Not suitable for parallel builds on multiple machines

**Use case:** Testing with a known UUID, or when UUID doesn't need to be unique per run

---

### ✅ Solution 2: File-Based Coordination (RECOMMENDED for Local Xcode)

**How it works:**
- First test process creates a UUID file
- All subsequent processes read from the same file
- Automatic staleness detection (>10s = new run)

**Implementation:**
Already implemented in `LaunchManager.swift`! Just run tests normally:

```bash
# In Xcode: Cmd+U
# Or:
xcodebuild test -scheme ReportPortalAgent
```

**Pros:**
- ✅ Zero configuration required
- ✅ Works automatically for local development
- ✅ Handles multiple parallel simulators
- ✅ Auto-cleanup of stale UUIDs

**Cons:**
- ❌ Only works on single machine (local development)
- ❌ Can't coordinate across multiple physical machines (CI/CD)

**Use case:** Local Xcode development (99% of use cases)

---

### ✅ Solution 3: `export` + Command-Line xcodebuild (CI/CD)

**How it works:**
- Use `export` to set environment variables in shell
- Child processes (including xcodebuild and tests) inherit them

**Implementation:**

```bash
#!/bin/zsh

# Generate dynamic UUID
LAUNCH_UUID=$(uuidgen)

# CRITICAL: Use 'export' to make available to child processes
export RP_LAUNCH_UUID="$LAUNCH_UUID"
export RP_LAUNCH_ID="$LAUNCH_UUID"

# Run tests - variables automatically inherited
xcodebuild test \
  -scheme ReportPortalAgent \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -parallel-testing-enabled YES
```

**Pros:**
- ✅ Dynamic UUID generation
- ✅ Works for CI/CD pipelines
- ✅ Scriptable and automatable

**Cons:**
- ❌ Doesn't work when running from Xcode UI (Cmd+U)
- ❌ Requires command-line execution

**Use case:** CI/CD pipelines (GitHub Actions, Jenkins, etc.)

---

### ❌ Solution 4: Xcode Pre-Action Scripts (DOESN'T WORK)

**Why it seems like it should work:**
- Pre-action scripts run before tests
- Can call `launchctl setenv` or `export`

**Why it DOESN'T work:**

```
Pre-Action Script:
  ├─ Runs in: Xcode build process
  ├─ Sets: launchctl setenv RP_LAUNCH_UUID "ABC..."
  └─ Scope: Current user session
  
Test Process (Simulator):
  ├─ Spawns as: Separate process
  ├─ Checks: ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"]
  └─ Result: nil ❌ (doesn't inherit launchctl environment)
```

**What was tested:**
```bash
# Pre-action script (DOESN'T WORK)
#!/bin/zsh
LAUNCH_UUID=$(uuidgen)
launchctl setenv RP_LAUNCH_UUID "$LAUNCH_UUID"  # Sets in build process
# Test process: Can't see the variable ❌
```

**Why:**
- `launchctl setenv` affects the current user session
- Simulator test processes spawn in isolated environments
- They don't inherit the `launchctl` environment

---

### ⚠️ Solution 5: Info.plist + Custom Build Settings (STATIC)

**How it works:**
- Define custom build settings in Xcode project
- Reference in Info.plist
- Read from Bundle at runtime

**Example:**

1. **Xcode Project Settings:**
   - Add User-Defined Setting: `RP_LAUNCH_UUID = <value>`

2. **Info.plist:**
   ```xml
   <key>ReportPortalLaunchUUID</key>
   <string>$(RP_LAUNCH_UUID)</string>
   ```

3. **Read in code:**
   ```swift
   let uuid = Bundle.main.object(forInfoDictionaryKey: "ReportPortalLaunchUUID") as? String
   ```

**Pros:**
- ✅ Works from Xcode UI
- ✅ Type-safe (defined in project)

**Cons:**
- ❌ **STATIC** - must rebuild to change value
- ❌ Not suitable for dynamic values
- ❌ Requires app rebuild

**Use case:** Configuration values that rarely change (API URLs, feature flags)

---

### ⚠️ Solution 6: xcconfig Files (STATIC)

**How it works:**
- Define variables in `.xcconfig` files
- Xcode loads them at build time
- Can be different per configuration (Debug/Release)

**Example:**

1. **Create `Debug.xcconfig`:**
   ```
   RP_LAUNCH_UUID = B60EA9AC-3C83-4D02-970C-74127CD73B0E
   ```

2. **Set in Xcode:**
   - Project → Info → Configurations → Debug → Set to Debug.xcconfig

3. **Read in code:** (via Info.plist or preprocessor macros)

**Pros:**
- ✅ Per-configuration values
- ✅ Can be version-controlled

**Cons:**
- ❌ **STATIC** - not dynamic
- ❌ Requires project setup

**Use case:** Configuration per build type (Debug vs Release)

---

## Summary: Which Solution to Use?

| Scenario | Solution | Why |
|----------|----------|-----|
| **Local Xcode development** | **File-Based Coordination** | Zero config, automatic |
| **CI/CD pipeline (single UUID across machines)** | **`export` + xcodebuild** | Dynamic, scriptable |
| **Testing with specific UUID (debugging)** | **Scheme Environment Variables** | Simple, manual |
| **Static config (API URLs, etc.)** | **Info.plist or xcconfig** | Type-safe, versioned |

---

## Verification Test

To test if environment variables are actually visible to tests:

```bash
# Run this script
./test_env_inheritance.sh

# Expected output:
# ✅ Swift sees RP_LAUNCH_UUID: <UUID>
# ✅ Swift sees RP_LAUNCH_ID: <UUID>
```

---

## Real-World Example: ReportPortal Agent

**Current implementation (Smart Fallback):**

```swift
// Priority 1: Environment variable (CI/CD)
if let envUUID = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"] {
    return envUUID  // CI/CD pipeline set this
}

// Priority 2: File-based coordination (Local Xcode)
return getOrCreateCoordinatedUUID()  // Automatic file-based
```

**Result:**
- ✅ Works in CI/CD (with `export`)
- ✅ Works in local Xcode (automatic file)
- ✅ Zero configuration for developers
- ✅ Reliable coordination across devices

---

## Why This is a Common Problem

The iOS/Xcode community has dealt with this for years:

1. **Simulator isolation:** Each simulator is a separate process with its own environment
2. **Xcode UI limitations:** No way to run shell commands in scheme environment variables
3. **Pre-action timing:** Pre-actions run in build process, not test process
4. **Process inheritance:** Test processes don't inherit `launchctl` environment

**Community consensus:**
- For **local dev**: Use file-based coordination or static scheme variables
- For **CI/CD**: Use `export` in shell scripts
- For **debugging**: Hardcode values temporarily in scheme

---

## Additional Resources

- Apple Documentation: [Customizing the Build Schemes for a Project](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project)
- Stack Overflow: "Passing environment variables to XCTest" (common question)
- XCTest Limitations: Environment variables are passed to test bundles, but timing matters

