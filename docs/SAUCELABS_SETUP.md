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
1. Queries ReportPortal for launches with `merge_group=regression-nightly` and matching `ci_run_id`
2. Finalizes any launches still in `IN_PROGRESS` state
3. Calls `POST /v2/{project}/launch/merge` with `mergeType: DEEP`
4. Outputs the merged launch URL

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

Controls whether the agent finalizes the launch or delegates to the merge script:

| Priority | Source | When used |
|----------|--------|-----------|
| 1 | `RP_SKIP_FINISH` env var (any non-empty value) | CI/CD where env vars reach the test process |
| 2 | `ReportPortalSkipFinish` = `true` in Info.plist | SauceLabs real devices (env vars blocked) |
| 3 | `false` (agent finalizes normally) | Default behavior |

### ci_run_id Resolution (2-tier)

Used to disambiguate concurrent CI runs:

| Priority | Source |
|----------|--------|
| 1 | `RP_CI_RUN_ID` env var |
| 2 | `GITHUB_RUN_ID` env var (auto-set by GitHub Actions) |

No Info.plist fallback — CI run IDs are per-invocation; baking them into a plist would defeat the purpose.

### Merge Script Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RP_ENDPOINT` | Yes | — | ReportPortal base URL (e.g. `https://rp.example.com`) |
| `RP_PROJECT` | Yes | — | ReportPortal project name |
| `RP_TOKEN` | Yes | — | ReportPortal API token |
| `RP_MERGE_GROUP` | Yes | — | Merge group to query |
| `RP_CI_RUN_ID` | Yes* | `$GITHUB_RUN_ID` | CI run identifier (*falls back to `GITHUB_RUN_ID`) |
| `RP_MERGE_FINALIZE_TIMEOUT` | No | `60` | Seconds to wait for in-progress launches to finalize |
| `RP_MERGED_LAUNCH_NAME` | No | `{RP_MERGE_GROUP} (merged)` | Name for the merged launch |

---

## Troubleshooting

### No launches found (merge script reports 0)

**Symptom:** `Found 0 launches` → `Nothing to merge. exit_code=0`

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

**400 "launches must have the same status":** One or more launches are still `IN_PROGRESS`. The merge script polls and attempts to finalize them. If finalization times out, increase `RP_MERGE_FINALIZE_TIMEOUT` (default: 60s).

**404 on merge endpoint:** Your ReportPortal instance may be older than 5.0. The `/v2/{project}/launch/merge` endpoint requires ReportPortal 5.0+.

**403 Forbidden:** The `RP_TOKEN` lacks permission to merge launches in the target project. Verify the token has project-level write access.

### Timeout conditions

The merge script has two timeout points:
1. **Finalize polling** (`RP_MERGE_FINALIZE_TIMEOUT`, default 60s): Waits for in-progress launches to reach terminal status.
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

## See Also

- [docs/GITHUB_ACTIONS_EXAMPLES.md](./GITHUB_ACTIONS_EXAMPLES.md) — Complete CI workflow examples
- [examples/saucectl/.sauce/config.yml](../examples/saucectl/.sauce/config.yml) — Example saucectl configuration
- [docs/SAUCELABS_FEASIBILITY_ANALYSIS.md](./SAUCELABS_FEASIBILITY_ANALYSIS.md) — Technical analysis of SauceLabs limitations
