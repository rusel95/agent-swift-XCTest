# ReportPortal Agent for XCTest

> Real-time reporting of XCTest / XCUITest runs to [ReportPortal](https://reportportal.io) — with first-class **parallel execution** and **SauceLabs multi-device merge** support.

[![CocoaPods](https://img.shields.io/cocoapods/v/ReportPortal.svg?style=flat)](http://cocoapods.org/pods/ReportPortal)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen.svg?style=flat)](https://swift.org/package-manager/)
[![Swift](https://img.shields.io/badge/Swift-5.5%2B-orange.svg?style=flat)](https://swift.org)
[![Platform](https://img.shields.io/cocoapods/p/ReportPortal.svg?style=flat)](http://cocoapods.org/pods/ReportPortal)
[![Validate](https://github.com/reportportal/agent-swift-XCTest/actions/workflows/validate.yml/badge.svg)](https://github.com/reportportal/agent-swift-XCTest/actions/workflows/validate.yml)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Slack](https://img.shields.io/badge/slack-join-brightgreen.svg)](https://slack.epmrpp.reportportal.io/)
[![StackOverflow](https://img.shields.io/badge/reportportal-stackoverflow-orange.svg?style=flat)](http://stackoverflow.com/questions/tagged/reportportal)

The agent hooks into XCTest via [`XCTestObservation`](https://developer.apple.com/documentation/xctest/xctestobservation) and streams your suites, test cases, statuses, logs, and attachments to a ReportPortal launch as they run — no changes to your test code required.

---

## Contents

- [Features](#features)
- [Compatibility](#compatibility)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Parallel Test Execution (v4.0+)](#parallel-test-execution-v40)
- [SauceLabs Real-Device Merge](#saucelabs-real-device-merge)
- [How It Works](#how-it-works)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Authors](#authors)
- [License](#license)

---

## Features

- 📡 **Zero-touch reporting** — add the agent as your test target's principal class; no test-code changes.
- 🧱 **Full hierarchy** — launches → suites → test cases, with statuses, durations, logs, and attachments.
- ⚡ **Parallel-execution ready (v4.0+)** — multiple simulator clones/devices report into a single launch via a shared `RP_LAUNCH_UUID`.
- ☁️ **SauceLabs real-device merge** — each isolated device creates its own launch; a post-run script merges them into one ([guide](docs/SAUCELABS_SETUP.md)).
- 🧩 **Flexible configuration** — env vars override `Info.plist`, with sensible defaults.
- 🏷️ **Metadata & tags** — device/OS attributes, custom tags, and test-plan-aware launch names.
- 🔁 **Idempotent finalize** — a launch already finished (HTTP 409) is treated as success, not an error.

## Compatibility

| | Minimum |
|---|---|
| Swift | 5.5 |
| Xcode | 13 |
| iOS | 15.0 |
| macOS | 12.0 |
| tvOS | 15.0 |
| watchOS | 8.0 |
| ReportPortal | 5.0 (API v2; merge endpoint requires 5.0+) |

> Parallel execution relies on Swift Concurrency, hence the iOS 15 / Swift 5.5 floor.

## Installation

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…**, enter the repository URL, and add the **`ReportPortalAgent`** library to your **test** target.

```text
https://github.com/reportportal/agent-swift-XCTest.git
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/reportportal/agent-swift-XCTest.git", from: "4.0.0")
```

```swift
.testTarget(
    name: "YourUITests",
    dependencies: [.product(name: "ReportPortalAgent", package: "agent-swift-XCTest")]
)
```

### CocoaPods

```ruby
pod 'ReportPortal'
```

```bash
pod install
```

## Quick Start

**1. Give your test target an `Info.plist`.** If it doesn't have one, create `YourTests/Info.plist` and set the target's *Info.plist File* build setting to that path.

**2. Add the ReportPortal keys** (see the [full reference](#configuration-reference)):

```xml
<key>NSPrincipalClass</key>
<string>ReportPortalAgent.RPListener</string>   <!-- CocoaPods: ReportPortal.RPListener -->

<key>PushTestDataToReportPortal</key>
<true/>
<key>ReportPortalURL</key>
<string>https://reportportal.example.com</string>  <!-- base URL; /api/v2/{project} is appended -->
<key>ReportPortalProjectName</key>
<string>your_project</string>
<key>ReportPortalToken</key>
<string>your_api_token</string>
<key>ReportPortalLaunchName</key>
<string>Regression</string>
```

![Info.plist example](./Example.png)

**3. Run your tests** as usual (`xcodebuild test …` or ⌘U). A launch appears in ReportPortal in real time.

## Configuration Reference

### `Info.plist` keys

| Key | Type | Required | Description |
|-----|------|----------|-------------|
| `NSPrincipalClass` | String | ✅ | `ReportPortalAgent.RPListener` (SPM) or `ReportPortal.RPListener` (CocoaPods). May be your own `XCTestObservation`. |
| `PushTestDataToReportPortal` | Bool **or** String | ✅ | Master on/off switch. `true`/`yes`/`1` enable reporting. |
| `ReportPortalURL` | String | ✅ | Base URL of your instance. The agent appends `/api/v2/{project}`. |
| `ReportPortalProjectName` | String | ✅ | ReportPortal project name. |
| `ReportPortalToken` | String | ✅ | API token (from RP account settings). |
| `ReportPortalLaunchName` | String | ✅ | Launch name. |
| `ReportPortalTags` | String | — | Comma-separated tags. |
| `IsDebugLaunchMode` | Bool | — | Marks the launch as debug mode. |
| `TestNameRules` | Dict | — | Display-name transforms (see below). |
| `ReportPortalMergeGroup` | String | — | Tags launches for SauceLabs post-run merge. |
| `ReportPortalSkipFinish` | Bool **or** String | — | Defers launch finalization to the merge script. |

### Environment variables

Env vars take priority over `Info.plist` (useful in CI where `Info.plist` is baked at build time):

| Variable | Purpose |
|----------|---------|
| `RP_LAUNCH_UUID` | Shared launch UUID so parallel workers report into **one** launch. |
| `RP_MERGE_GROUP` | Overrides `ReportPortalMergeGroup`. |
| `RP_SKIP_FINISH` | Overrides `ReportPortalSkipFinish` (`true`/`yes`/`1` vs `false`/`no`/`0`). |
| `RP_CI_RUN_ID` | Disambiguates concurrent CI runs; falls back to `GITHUB_RUN_ID`. |
| `TEST_PLAN_NAME` | Appends the test-plan name to the launch name. |

### `TestNameRules`

```xml
<key>TestNameRules</key>
<dict>
    <key>StripTestPrefix</key><true/>          <!-- testLoginWorks → LoginWorks -->
    <key>WhiteSpaceOnUnderscore</key><true/>   <!-- login_works   → login works -->
    <key>WhiteSpaceOnCamelCase</key><true/>    <!-- LoginWorks     → Login Works -->
</dict>
```

### Test plan name in the launch name

Add `TEST_PLAN_NAME` to your `.xctestplan` (or override per-run in CI) to get launch names like `Regression: Smoke_Tests`:

```json
{ "defaultOptions": { "environmentVariableEntries": [ { "key": "TEST_PLAN_NAME", "value": "Smoke Tests" } ] } }
```

```bash
TEST_PLAN_NAME="Nightly" xcodebuild test …   # CI override
```

Spaces are replaced with underscores for compatibility.

## Parallel Test Execution (v4.0+)

Run tests across multiple simulators simultaneously to cut pipeline time, while preserving the test hierarchy in ReportPortal.

```bash
# Option A — clone one device type N times
xcodebuild test -scheme YourScheme -testPlan YourPlan \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -parallel-testing-enabled YES -maximum-parallel-testing-workers 4

# Option B — explicit device matrix
xcodebuild test -scheme YourScheme -testPlan YourPlan \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' \
  -parallel-testing-enabled YES
```

### One shared launch in CI

By default each worker creates its **own** launch. To report all workers into a **single** launch, export a shared UUID **before** the test run:

```bash
export RP_LAUNCH_UUID=$(uuidgen)
xcodebuild test -scheme YourScheme -testPlan YourPlan \
  -parallel-testing-enabled YES -maximum-parallel-testing-workers 4
```

The first worker creates the launch; the others join it (HTTP 409 is handled as success).

> ⚠️ **Don't generate the UUID in a build-phase script.** Build phases only run when sources change, so a re-run without code changes reuses a stale UUID and joins the previous run's (already-finished) launch. Always set `RP_LAUNCH_UUID` from the shell/CI before `xcodebuild`.

### Worker-count guidance

| Environment | Workers |
|-------------|---------|
| Local (8+ cores) | 4 |
| Local (4–6 cores) | 2–3 |
| GitHub Actions | 2 |
| Self-hosted (cores N) | N / 2 |

For local Xcode runs that produce separate launches, you can also merge them by hand in **ReportPortal → Launches → Merge**.

![Merge example](./example_merge.png)

## SauceLabs Real-Device Merge

SauceLabs real devices are isolated — they share neither a filesystem nor environment variables, so the simulator-style shared-UUID approach can't work. Instead each device creates its own launch (tagged with a `merge_group`), defers finalization (`ReportPortalSkipFinish`), and a post-run script merges them into one launch.

The merge scripts and CI workflow examples live in the consuming project (not in this library).

## How It Works

```text
XCTest run
   │  XCTestObservation callbacks
   ▼
RPListener ──► LaunchUUID           (launch identity: shared RP_LAUNCH_UUID or per-worker UUID)
   │            │
   │            ▼
   └─────────► ReportingService ──► HTTPClient ──► ReportPortal API v2
                (async/await, stateless suite/test/log calls)
```

- **`RPListener`** — the `XCTestObservation` entry point; resolves configuration and translates test events into API calls. Uses a "launch gate" Task to guarantee launch exists before any suites/tests are reported.
- **`LaunchUUID`** — resolves launch UUID once per process (`RP_LAUNCH_UUID` env var or auto-generated).
- **`ReportingService`** — stateless async/await wrapper over the ReportPortal v2 API.
- **Idempotency** — joining an existing launch (HTTP 409 on start) and finalizing an already-finished launch (HTTP 409 on finish) are both treated as success.

## Contributing

```bash
swift build                                   # build the library
xcodebuild test -scheme Example \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ExampleUnitTests              # fast unit tests
```

Issues and pull requests are welcome. Please run the test suite above before opening a PR.

## Authors

- [@rusel95](https://github.com/rusel95) · <ruslanpopesku95@gmail.com>
- ReportPortal Team · <support@reportportal.io>
- [@DarthRumata](https://github.com/DarthRumata) (Stas Kirichok, [Windmill Smart Solutions](https://github.com/Windmill-Smart-Solutions))
- @SergeVKom · <sergvkom@gmail.com> (original library)

## License

Licensed under the [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) license — see the [LICENSE](LICENSE) file.
