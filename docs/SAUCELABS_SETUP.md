# SauceLabs Setup Guide

Run parallel XCUITests on SauceLabs real devices and merge results into a single ReportPortal launch.

---

## Quick Start (under 30 minutes)

### Prerequisites

- **saucectl** CLI installed (`npm i -g saucectl`)
- **ReportPortal** 5.0+ instance with a valid API token
- **GitHub Actions** (or any CI with post-step capability)
- macOS runner for building `.ipa` + `.xctestrun`
- `jq` and `curl` available on the runner that executes the merge step

### Overview

SauceLabs real devices are physically isolated — they don't share filesystems or environment variables with each other. The agent's standard `RP_LAUNCH_UUID` sharing (which works for Xcode simulator parallel) cannot work here. Instead, each device creates its own ReportPortal launch, and a post-run step merges them.

**Choose your approach:**

| Approach | How it works | Reliability | Setup effort |
|----------|-------------|-------------|--------------|
| **A: Xctestrun Injection** | Inject shared UUID into `.xctestrun` before upload; all devices share one launch | Depends on SauceLabs honoring xctestrun env vars | Medium |
| **C: Post-Run Merge** | Each device creates its own launch; merge script combines them after all shards finish | Guaranteed (no SauceLabs dependency) | Low |

**Recommendation:** Use **Approach C** for production. Use **Approach A** as an optimization if your SauceLabs setup honors `.xctestrun` `EnvironmentVariables`.

---

## Approach A: Xctestrun Injection

Best when SauceLabs preserves `.xctestrun` `EnvironmentVariables` on real devices. Produces a single launch directly (no merge needed).

### Step 1: Build IPA + xctestrun

```bash
xcodebuild build-for-testing \
  -scheme YourScheme \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./DerivedData

# Locate artifacts
IPA_PATH=$(find ./DerivedData -name "*.ipa" | head -1)
XCTESTRUN_PATH=$(find ./DerivedData -name "*.xctestrun" | head -1)
```

### Step 2: Generate UUID and inject

```bash
export RP_LAUNCH_UUID=$(uuidgen)

# Inject into xctestrun (all devices will read this UUID)
scripts/inject_xctestrun_env.sh "$XCTESTRUN_PATH" RP_LAUNCH_UUID "$RP_LAUNCH_UUID"
```

The injection script uses `PlistBuddy` to set `RP_LAUNCH_UUID` in the test target's `EnvironmentVariables` dictionary.

### Step 3: Run saucectl

```bash
saucectl run --config .sauce/config.yml
```

All devices read the same UUID → V2 API deduplicates (409 Conflict = success) → single launch.

### Step 4 (Optional): Merge as safety net

If some devices didn't pick up the UUID, they'll create separate launches. Run the merge script as a fallback:

```bash
export RP_ENDPOINT="https://reportportal.example.com"
export RP_PROJECT="your_project"
export RP_TOKEN="${{ secrets.RP_TOKEN }}"
export RP_MERGE_GROUP="regression-$(date +%Y%m%d)"
export RP_CI_RUN_ID="${GITHUB_RUN_ID}"

scripts/merge_rp_launches.sh
```

---

## Approach C: Post-Run Merge (Guaranteed)

Each device creates its own launch with shared attributes. After all shards finish, a merge script combines them into one launch. This approach has **zero dependency on SauceLabs env var behavior**.

### Step 1: Configure Info.plist

Since environment variables set via `saucectl --env` or YAML `env:` do **not** reach the XCUITest process on real devices ([saucectl issue #398](https://github.com/saucelabs/saucectl/issues/398)), configure these in your **Test Target's Info.plist**:

| Key | Value | Purpose |
|-----|-------|---------|
| `ReportPortalMergeGroup` | e.g. `regression-nightly` | Groups launches for merge discovery |
| `ReportPortalSkipFinish` | `YES` | Prevents workers from finalizing launches (delegated to merge script) |

`ReportPortalSkipFinish` accepts either a **Boolean** (`YES`/`NO`) or a **String** (`"true"`/`"yes"`/`"1"` vs `"false"`/`"no"`/`"0"`) — both are recognized, so a value stored as a String in Xcode's plist editor still works.

The agent reads these from Info.plist as a fallback when the corresponding env vars are absent.

### Step 2: Build and run

```bash
# Build (Info.plist values are baked into the test binary)
xcodebuild build-for-testing \
  -scheme YourScheme \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./DerivedData

# Run on SauceLabs
saucectl run --config .sauce/config.yml
```

### Step 3: Merge launches

After all shards complete, run the merge script:

```bash
export RP_ENDPOINT="https://reportportal.example.com"
export RP_PROJECT="your_project"
export RP_TOKEN="${{ secrets.RP_TOKEN }}"
export RP_MERGE_GROUP="regression-nightly"
export RP_CI_RUN_ID="${GITHUB_RUN_ID}"

scripts/merge_rp_launches.sh
```

The script:
1. Queries ReportPortal for launches tagged `merge_group=regression-nightly` (query values are URL-encoded, so spaces/`&` in a group name are safe)
2. If `RP_CI_RUN_ID` is set, narrows the result to launches that also carry that `ci_run_id` (filtered client-side to avoid cross-run over-matching); on real-device runs that have no `ci_run_id` it falls back to the merge_group-only result and logs a warning
3. Waits for those launches to finish; force-finishes and re-checks any still `IN_PROGRESS` before merging
4. Calls `POST /api/v2/{project}/launch/merge` with `mergeType: DEEP`
5. Outputs the merged launch URL

---

## Configuration Reference

### UUID Resolution (2-tier)

The agent resolves the launch UUID in this order:

| Priority | Source | When used |
|----------|--------|-----------|
| 1 | `RP_LAUNCH_UUID` env var | CI/CD mode — all workers share one launch |
| 2 | Per-worker `UUID()` | Local/isolated mode — each worker gets its own launch |

### merge_group Resolution (3-tier)

Used to tag launches for post-run merge discovery:

| Priority | Source | When used |
|----------|--------|-----------|
| 1 | `RP_MERGE_GROUP` env var | CI/CD where env vars reach the test process |
| 2 | `ReportPortalMergeGroup` in Info.plist | SauceLabs real devices (env vars blocked) |
| 3 | `nil` (no attribute emitted) | Standard Xcode parallel / sequential runs |

### skipFinish Resolution (3-tier)

Controls whether the agent finalizes the launch or delegates to the merge script. Both the
env var and the Info.plist key accept a Boolean or a String — `true`/`yes`/`1` enable skip,
`false`/`no`/`0` disable it (so an explicit `RP_SKIP_FINISH=false` is honored, **not** treated as merely "set"):

| Priority | Source | When used |
|----------|--------|-----------|
| 1 | `RP_SKIP_FINISH` env var (`true`/`yes`/`1`) | CI/CD where env vars reach the test process |
| 2 | `ReportPortalSkipFinish` in Info.plist (Boolean or String) | SauceLabs real devices (env vars blocked) |
| 3 | `false` (agent finalizes normally) | Default behavior |

### ci_run_id Resolution (2-tier)

Used to disambiguate concurrent CI runs. The **first non-empty** value wins (an empty
`RP_CI_RUN_ID` does not suppress the `GITHUB_RUN_ID` fallback):

| Priority | Source |
|----------|--------|
| 1 | `RP_CI_RUN_ID` env var |
| 2 | `GITHUB_RUN_ID` env var (auto-set by GitHub Actions) |

There is **no Info.plist fallback** — CI run IDs are per-invocation, so baking one into a plist would defeat the purpose.

> ⚠️ **Concurrency caveat on real devices.** Because env vars don't reach the XCUITest process on SauceLabs real devices, those launches carry `merge_group` but **not** `ci_run_id`. If two CI runs share the same `merge_group` at the same time, the merge cannot tell them apart. Use a **run-unique merge group** on real devices (e.g. set `ReportPortalMergeGroup` build-time or pass `RP_MERGE_GROUP="regression-${GITHUB_RUN_ID}"` to the merge step) to keep concurrent runs isolated.

### Merge Script Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RP_ENDPOINT` | Yes | — | ReportPortal base URL (e.g. `https://rp.example.com`) |
| `RP_PROJECT` | Yes | — | ReportPortal project name |
| `RP_TOKEN` | Yes | — | ReportPortal API token |
| `RP_MERGE_GROUP` | Yes | — | Merge group to query |
| `RP_CI_RUN_ID` | No | `$GITHUB_RUN_ID` | CI run identifier; narrows the query when present (falls back to `GITHUB_RUN_ID`) |
| `RP_MERGE_FINALIZE_TIMEOUT` | No | `120` | Seconds to wait for in-progress launches to finalize (integer only; a unit suffix like `60s` is rejected and the default is used) |
| `RP_MERGED_LAUNCH_NAME` | No | `{RP_MERGE_GROUP} (merged)` | Name for the merged launch |

---

## Troubleshooting

### No launches found (merge script reports 0)

**Symptom:** `No launches found for merge_group=... (nothing to merge)` → the script exits `0`, so an `if: always()` merge step does **not** fail the pipeline when there is simply nothing to merge.

**Causes:**
1. **Attributes not reaching the agent.** SauceLabs `--env` and YAML `env:` do NOT inject env vars into XCUITest on real devices. Use Info.plist keys (`ReportPortalMergeGroup`) instead.
2. **Mismatched merge_group value.** The value in Info.plist must exactly match `RP_MERGE_GROUP` passed to the merge script.
3. **Launches not yet created.** If shards are still running, launches may not exist yet. Ensure the merge step runs **after** all saucectl shards complete.

**Fix:** Inspect a launch in ReportPortal → Attributes tab. Confirm `merge_group` and `ci_run_id` attributes are present with expected values.

### Partial device failures

**Symptom:** Fewer launches than expected (e.g., 6 of 8).

**Behavior:** The merge script merges whatever launches it finds and logs a warning about the count. It does **not** fail the workflow.

**Investigation:** Check SauceLabs dashboard for failed/timed-out devices. The missing devices never created a ReportPortal launch.

### Merge API errors

**400 "launches must have the same status":** One or more launches are still `IN_PROGRESS`. The merge script polls, force-finishes, and re-checks them before merging. If finalization times out, increase `RP_MERGE_FINALIZE_TIMEOUT` (default: 120s).

**404 on merge endpoint:** Your ReportPortal instance may be older than 5.0. The `/v2/{project}/launch/merge` endpoint requires ReportPortal 5.0+.

**403 Forbidden:** The `RP_TOKEN` lacks permission to merge launches in the target project. Verify the token has project-level write access.

### Timeout conditions

The merge script has two timeout points:
1. **Finalize polling** (`RP_MERGE_FINALIZE_TIMEOUT`, default 120s): Waits for in-progress launches to reach terminal status.
2. **curl request timeout** (30s per request): Individual API calls.

If your ReportPortal instance is slow, increase `RP_MERGE_FINALIZE_TIMEOUT`.

### Token masking

The merge script masks `RP_TOKEN` in all log output. If you see `***` in error messages where a token would appear, this is intentional. To debug authentication issues, verify the token directly via:

```bash
curl -s -H "Authorization: Bearer $RP_TOKEN" \
  "$RP_ENDPOINT/api/v1/$RP_PROJECT/launch?page.size=1"
```

### HTTPS_PROXY and custom CA certificates

The merge script respects `HTTPS_PROXY` (and `https_proxy`) for all API calls. For environments with custom CA certificates:

```bash
export CURL_CA_BUNDLE=/path/to/custom-ca-bundle.crt
```

The script does **not** use `--insecure` / `-k`. If you need to bypass TLS verification (not recommended), set it in your environment before invoking the script.

---

## QA: Testing this feature from the fork branch

This feature ships on a branch in a fork **before** it is released to the official package.
This section is the end-to-end script for QA to validate it on real SauceLabs devices and send
back actionable evidence.

> **Fork & branch under test:** `https://github.com/rusel95/agent-swift-XCTest.git` → branch `003-saucelab-integration`

### Step 1 — Point your app at the fork branch (not `main`, not the official repo)

**Option A — Xcode UI:** Project → **Package Dependencies** → if `agent-swift-XCTest` is already
listed, double-click it; otherwise **+** → add the URL above. Set **Dependency Rule → Branch** and
enter `003-saucelab-integration`, then **Update Package**.

**Option B — `Package.swift`:**

```swift
.package(
    url: "https://github.com/rusel95/agent-swift-XCTest.git",
    branch: "003-saucelab-integration"
)
```

```bash
swift package resolve   # then verify the resolved pin shows the branch, not a version tag
```

> If the package was cached, force a refresh: **File → Packages → Reset Package Caches**, then
> **Product → Clean Build Folder** (⇧⌘K) and delete `~/Library/Developer/Xcode/DerivedData`.

### Step 2 — Configure the **Test Target** Info.plist

Real devices don't receive env vars, so configure via Info.plist (see the table in *Approach C*):

| Key | Type | Value |
|-----|------|-------|
| `ReportPortalMergeGroup` | String | a **run-unique** value, e.g. `qa-saucelabs-${BUILD_ID}` (avoids cross-run merges) |
| `ReportPortalSkipFinish` | Boolean **or** String | `YES` / `"true"` |

### Step 3 — Build, run on ≥2 devices, then merge

```bash
xcodebuild build-for-testing -scheme YourScheme \
  -destination 'generic/platform=iOS' -derivedDataPath ./DerivedData
saucectl run --config .sauce/config.yml          # at least 2 real devices

# After ALL shards finish:
export RP_ENDPOINT="https://your-reportportal" RP_PROJECT="your_project" RP_TOKEN="…"
export RP_MERGE_GROUP="qa-saucelabs-<the same value as the plist>"
export RP_CI_RUN_ID="qa-$(date +%s)"
./scripts/merge_rp_launches.sh 2>&1 | tee merge.log   # tee → keep the full log for feedback
```

### Step 4 — What to verify in ReportPortal

| Check | Expected |
|-------|----------|
| One launch per device exists before merge | status `IN_PROGRESS` (skipFinish working) |
| Each launch's **Attributes** tab | `merge_group` present; `ci_run_id` present only if env vars reached the process |
| Merge script output | `Merged launch: <URL>` |
| Merged launch | single launch, test count = sum across devices |

### Step 5 — Logs & evidence to send back (please attach all of these)

The faster we can read your run, the faster we fix issues. Capture:

1. **SauceLabs console output**, per device — search for the agent markers: `🎬` (launch start),
   `📡` (launch created), `📎` (merge_group), `⏭️` (skipFinish), `🏁` (bundle finished).
2. **`merge.log`** — the full stdout+stderr of the merge script from Step 3 (the token is
   auto-masked as `***`, so it is safe to share).
3. **The `environment_variables` attachment** produced by `SauceLabsValidationTest` (SauceLabs →
   test → **Artifacts**), if you ran the Approach-A validation.
4. **`xcresult` bundle** if SauceLabs lets you download it.
5. **ReportPortal screenshots:** a per-device launch **Attributes** tab, and the final **merged** launch.
6. **A filled feedback form:**

```
Branch tested:        003-saucelab-integration (fork rusel95)
Approach:             A (xctestrun) | C (post-run merge)
Devices / OS:         e.g. iPhone 16 (18.0), iPhone 15 Pro (17.0)
merge_group used:     …
ci_run_id present?:   yes | no
Launches before merge: N (expected M)
Merge result:         merged URL | failed (paste merge.log tail)
Anything unexpected:  …
```

> 📨 Post the form + attachments on the PR: <https://github.com/reportportal/agent-swift-XCTest/pull/32>

### Step 6 — Revert to the official release when done

Switch the dependency back to `https://github.com/reportportal/agent-swift-XCTest.git` with a
version rule (e.g. **Up to Next Major** from the new release) once the PR is merged and tagged.

---

## See Also

- [GITHUB_ACTIONS_EXAMPLES.md](./GITHUB_ACTIONS_EXAMPLES.md) — Complete CI workflow examples
- [../examples/saucectl/.sauce/config.yml](../examples/saucectl/.sauce/config.yml) — Example saucectl configuration
- [../README.md](../README.md) — Agent overview, installation, and configuration reference
- [../scripts/tests/](../scripts/tests/) — Self-tests for the merge and inject scripts
