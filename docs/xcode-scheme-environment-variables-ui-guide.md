# How to Set Environment Variables in Xcode Scheme (UI Guide)

## ✅ YES - Xcode DOES Support Environment Variables!

The community has been using this for years. Here's exactly how to do it:

## Step-by-Step Guide

### 1. Open Scheme Editor

**Method 1:** Click scheme dropdown → "Edit Scheme..."
```
┌─────────────────────────────┐
│ ReportPortalAgent ▼         │ ← Click here
│   Edit Scheme...            │ ← Select this
│   New Scheme...             │
│   Manage Schemes...         │
└─────────────────────────────┘
```

**Method 2:** Menu bar → **Product** → **Scheme** → **Edit Scheme...**

### 2. Navigate to Test Arguments

```
Scheme Editor:
┌──────────────────────────────────────────────┐
│ Build          │ Test  ← Select this         │
│ Run            │                              │
│ Profile        │   ┌────────────────────────┐│
│ Analyze        │   │ Info                   ││
│ Archive        │   │ Arguments  ← Click this││
│                │   │ Options                ││
│                │   └────────────────────────┘│
└──────────────────────────────────────────────┘
```

### 3. Add Environment Variables

In the **Arguments** tab, you'll see two sections:

```
┌──────────────────────────────────────────────────────────┐
│ Arguments Passed On Launch                               │
│ ┌──────────────────────────────────────────────────────┐ │
│ │  (empty - for command-line arguments)                │ │
│ └──────────────────────────────────────────────────────┘ │
│                                                          │
│ Environment Variables                                    │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ [+] [-]  Name                    Value            ✓  │ │
│ │                                                      │ │
│ │  RP_LAUNCH_UUID                  <paste_uuid>    ✓  │ │ ← Add this
│ │  RP_LAUNCH_ID                    <paste_uuid>    ✓  │ │ ← And this
│ └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘

Click [+] to add new environment variable
```

### 4. Fill in the Values

Click the **[+]** button and enter:

| Name | Value | Enabled |
|------|-------|---------|
| `RP_LAUNCH_UUID` | `B60EA9AC-3C83-4D02-970C-74127CD73B0E` | ✓ |
| `RP_LAUNCH_ID` | `B60EA9AC-3C83-4D02-970C-74127CD73B0E` | ✓ |

**Note:** You can use any UUID here. Generate one:
```bash
uuidgen
# Example output: B60EA9AC-3C83-4D02-970C-74127CD73B0E
```

### 5. Click "Close" to Save

The scheme is now configured! When you run tests (Cmd+U), these environment variables will be available to your test processes.

---

## Verification

After setting environment variables, run a simple test to verify:

```swift
func testEnvironmentVariables() {
    let uuid = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"]
    XCTAssertNotNil(uuid, "RP_LAUNCH_UUID should be set in scheme")
    print("✅ RP_LAUNCH_UUID = \(uuid ?? "nil")")
}
```

Expected output:
```
✅ RP_LAUNCH_UUID = B60EA9AC-3C83-4D02-970C-74127CD73B0E
```

---

## This Works For:

- ✅ Running tests from Xcode UI (Cmd+U)
- ✅ Running tests from command line: `xcodebuild test -scheme X`
- ✅ Single device or multiple parallel simulators
- ✅ Both shared and user-specific schemes

---

## The Limitation (Why We Use File-Based)

**Problem:** Values are **STATIC**

If you want a **unique UUID for each test run**, you have two options:

1. **Manual update:** Generate UUID, paste into scheme, run tests (tedious)
2. **File-based:** Our current implementation - automatic, no configuration

**Our solution:**
- Use scheme environment variables for **static values** (debugging, specific UUID)
- Use **file-based coordination** for **dynamic UUIDs** (normal development)
- Use **`export` + xcodebuild** for **CI/CD** (pipeline scripts)

---

## Editing Scheme XML Directly (Advanced)

If you want to edit the `.xcscheme` file directly:

```xml
<TestAction
   buildConfiguration = "Debug"
   shouldUseLaunchSchemeArgsEnv = "YES">
   <EnvironmentVariables>
      <EnvironmentVariable
         key = "RP_LAUNCH_UUID"
         value = "B60EA9AC-3C83-4D02-970C-74127CD73B0E"
         isEnabled = "YES">
      </EnvironmentVariable>
      <EnvironmentVariable
         key = "RP_LAUNCH_ID"
         value = "B60EA9AC-3C83-4D02-970C-74127CD73B0E"
         isEnabled = "YES">
      </EnvironmentVariable>
   </EnvironmentVariables>
   <!-- rest of scheme -->
</TestAction>
```

**File location:**
- Shared scheme: `YourProject.xcodeproj/xcshareddata/xcschemes/YourScheme.xcscheme`
- User scheme: `YourProject.xcodeproj/xcuserdata/<user>.xcuserdatad/xcschemes/YourScheme.xcscheme`

---

## Real-World Usage Examples

### Example 1: Testing with Specific Launch ID (Debugging)

You found a bug in launch `123-456-789` on ReportPortal. Set the environment variable:

```
Name: RP_LAUNCH_ID
Value: 123-456-789
```

Now when you run tests, they'll report to that specific launch (for debugging).

### Example 2: API Endpoint Configuration

```
Name: RP_ENDPOINT
Value: https://reportportal.example.com

Name: RP_TOKEN
Value: your-token-here
```

These can be read in your configuration:
```swift
let endpoint = ProcessInfo.processInfo.environment["RP_ENDPOINT"] ?? "default-endpoint"
```

### Example 3: Feature Flags

```
Name: ENABLE_EXPERIMENTAL_FEATURE
Value: true
```

---

## Summary

**YES**, Xcode supports environment variables in schemes! The community uses this all the time for:
- API endpoints
- Feature flags
- Debug settings
- Static configuration values

**However**, for **dynamic UUID generation**, you need:
- CI/CD: `export` in shell scripts
- Local dev: File-based coordination (our current implementation)

Our current solution is actually the **community best practice** - smart fallback between environment variables (CI/CD) and file-based (local dev). 🎯

