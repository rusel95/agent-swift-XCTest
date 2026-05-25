# QA Testing Guide: SauceLabs Integration Branch

This guide explains how to test the SauceLabs parallel merge feature before it's released.

---

## Step 1: Point your project to the feature branch

The feature lives on a branch in a fork. You need to temporarily switch your SPM dependency to pull from there.

### Option A: Xcode UI

1. Open your project in Xcode
2. Select your project in the navigator → **Package Dependencies** tab
3. If `ReportPortal` / `agent-swift-XCTest` is already listed:
   - Double-click the package
   - Change **Location** to:
     ```
     https://github.com/rusel95/agent-swift-XCTest.git
     ```
   - Change **Dependency Rule** to **Branch**
   - Enter: `003-saucelab-integration`
   - Click **Update Package**
4. If not yet added:
   - **File → Add Package Dependencies...**
   - Paste: `https://github.com/rusel95/agent-swift-XCTest.git`
   - Set rule to **Branch** → `003-saucelab-integration`
   - Add to your test target

### Option B: Package.swift

Replace your existing ReportPortal dependency with:

```swift
.package(
    url: "https://github.com/rusel95/agent-swift-XCTest.git",
    branch: "003-saucelab-integration"
)
```

Then run:

```bash
swift package resolve
```

### Verify it worked

After resolving, check in Xcode: **File → Packages → Resolve Package Versions**. The package should show the branch name, not a version tag.

---

## Step 2: Configure your test target

Add these keys to your **Test Target's Info.plist** (not the app target):

| Key | Type | Value | Purpose |
|-----|------|-------|---------|
| `ReportPortalMergeGroup` | String | `qa-saucelabs-validation` | Tags launches for merge discovery |
| `ReportPortalSkipFinish` | Boolean | `YES` | Prevents each device from finalizing its launch |

> **Why Info.plist?** SauceLabs real devices do NOT pass environment variables to the XCUITest process. Info.plist is the only reliable way to configure the agent on real devices.

---

## Step 3: Build for testing

```bash
xcodebuild build-for-testing \
  -scheme YourTestScheme \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./DerivedData
```

This produces the `.ipa` and `.xctestrun` artifacts needed for SauceLabs.

---

## Step 4: Run on SauceLabs (2+ devices)

Run your tests on at least 2 real devices to validate the parallel merge:

```bash
saucectl run --config .sauce/config.yml
```

Each device will create its own ReportPortal launch (not finalized, because `ReportPortalSkipFinish = YES`).

---

## Step 5: Run the merge script

After all SauceLabs shards complete, run:

```bash
export RP_ENDPOINT="https://your-reportportal-instance.com"
export RP_PROJECT="your_project_name"
export RP_TOKEN="your_api_token"
export RP_MERGE_GROUP="qa-saucelabs-validation"
export RP_CI_RUN_ID="local-test-$(date +%s)"

./scripts/merge_rp_launches.sh
```

> **Note:** The `scripts/` directory is in the `agent-swift-XCTest` repo, not your app repo. Clone or copy the scripts from:
> ```
> https://github.com/rusel95/agent-swift-XCTest/tree/003-saucelab-integration/scripts
> ```

---

## Step 6: Verify in ReportPortal

Open your ReportPortal instance and check:

| What to check | Expected result |
|---------------|-----------------|
| Individual launches exist (before merge) | One per SauceLabs device, status = `IN_PROGRESS` |
| Each launch has `merge_group` attribute | Value = `qa-saucelabs-validation` |
| Each launch has `ci_run_id` attribute | Value = whatever you set in `RP_CI_RUN_ID` |
| Merge script output | Shows "Merged launch: <URL>" |
| Merged launch in ReportPortal | Single launch with all test results combined |
| Test count in merged launch | Sum of tests from all devices |
| No duplicate test items | Each test appears once per device (expected) |

---

## Troubleshooting

### "Found 0 launches"

- Confirm `ReportPortalMergeGroup` in Info.plist matches `RP_MERGE_GROUP` exactly (case-sensitive)
- Confirm the agent is actually integrated (check your test target links `ReportPortal` library)
- Wait for all shards to finish before running the merge script

### Launches exist but aren't merging

- Check that `RP_ENDPOINT` doesn't have a trailing slash
- Verify your `RP_TOKEN` has write access to the project
- Check ReportPortal version is 5.0+ (merge API requirement)

### Agent not reporting at all

- Verify the SPM dependency resolved to the branch (not a cached old version)
- Clean build folder: **Product → Clean Build Folder** (Cmd+Shift+K)
- Delete DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData`

---

## After testing: revert to official release

Once the PR is merged and a new version is tagged, switch back:

### Xcode UI
- Change **Location** back to: `https://github.com/reportportal/agent-swift-XCTest.git`
- Change **Dependency Rule** to **Up to Next Major Version** → `4.0.0` (or the new release)

### Package.swift
```swift
.package(
    url: "https://github.com/reportportal/agent-swift-XCTest.git",
    from: "4.1.0" // new version after merge
)
```

---

## Questions?

Reach out to @rusel95 on the PR: https://github.com/reportportal/agent-swift-XCTest/pull/32
