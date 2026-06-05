# SauceLabs Setup Guide

Run parallel XCUITests on SauceLabs real devices and merge the results into a **single**
ReportPortal launch.

---

## Why SauceLabs needs a special recipe

SauceLabs real devices are physically isolated — they don't share a filesystem, environment
variables, or process group. Two consequences drive the whole design:

1. **Env vars don't reach the test process.** Neither `saucectl --env` nor YAML `env:` inject
   variables into the XCUITest process on real devices
   ([saucectl #398](https://github.com/saucelabs/saucectl/issues/398) — "Virtual Devices Only").
   So the agent's `RP_LAUNCH_UUID` sharing (which works for Xcode simulator parallel) **cannot**
   work here.
2. **SauceLabs regenerates the `.xctestrun`.** It builds its own from the uploaded `.ipa + .ipa`,
   so anything you inject into the build's `.xctestrun` is discarded (you'll see
   `XCTestRun Config File = null` in the job metadata).

The **only** configuration that survives to the device is what is **compiled into the test bundle's
`Info.plist` at build time**.

**The approach:** each device creates its own launch tagged with a shared, **run-unique**
`merge_group`; after all shards finish, a post-run merge step combines exactly this run's launches.

---

## Quick Start

### Prerequisites

- **saucectl** CLI (`npm i -g saucectl`)
- **ReportPortal 5.0+** with an API token that can merge launches (member/PM role)
- A CI with a post-step capability (e.g. GitHub Actions)
- macOS runner for building `.ipa` + test-runner `.ipa`
- `jq` and `curl` on the runner that executes the merge step, and **network access to ReportPortal**

### Step 1 — Inject a run-unique `merge_group` (before build)

Set the test target's `ReportPortalMergeGroup` to a **run-unique** value, injected **before**
`xcodebuild` so it is compiled into the bundle and signed normally:

```bash
MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"   # unique per run + re-run
PLIST="ExampleUITests/Info.plist"     # ← your test target's INFOPLIST_FILE
/usr/libexec/PlistBuddy -c "Delete :ReportPortalMergeGroup" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ReportPortalMergeGroup string $MERGE_GROUP" "$PLIST"
```

> **Do not patch the built/signed `.xctest`.** Modifying a file inside the signed runner bundle
> invalidates its code signature and it won't install on a real device. Always inject into the
> **source** `Info.plist` before the build (or via an `xcodebuild` build setting — see below).

> **Do not set `ReportPortalSkipFinish`** for a first working integration — see
> [skipFinish](#skipfinish-resolution-3-tier) below for why.

### Step 2 — Build and run

```bash
xcodebuild build-for-testing \
  -scheme YourScheme \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ./DerivedData

saucectl run --config .sauce/config.yml        # blocks until all shards finish
```

### Step 3 — Merge launches (next step, same job)

`saucectl run` is blocking, so the merge is simply the next step — no special post-action needed:

```bash
export RP_ENDPOINT="https://reportportal.example.com"
export RP_PROJECT="your_project"
export RP_TOKEN="…"                                  # same token as in Info.plist works
export RP_MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"   # SAME value as Step 1
# Wait for all shard launches before merging (avoids "merged 4 of 6"). Pick ONE:
export RP_DISCOVER_STABLE_POLLS="3"   # count-agnostic: merge once no new launch appears for 3 polls (use if the count varies)
# export RP_EXPECTED_LAUNCHES="6"     # OR exact shard count, if it's fixed

scripts/merge_rp_launches.sh
```

The script:
1. Queries ReportPortal for launches tagged `merge_group=<your run-unique value>` (values are
   URL-encoded, so spaces/`&`/`#` are safe).
2. Waits for those launches to finish; force-finishes and re-checks any still `IN_PROGRESS`.
3. Calls `POST /api/v2/{project}/launch/merge` with `mergeType: DEEP`.
4. Outputs the merged launch URL.

Because the merge group is run-unique, you don't need `ci_run_id` on SauceLabs — leave
`RP_CI_RUN_ID` unset for real-device runs.

See [GITHUB_ACTIONS_EXAMPLES.md](./GITHUB_ACTIONS_EXAMPLES.md) for a complete two-job workflow.

---

## Alternative injection: `xcodebuild` build setting

Instead of `PlistBuddy`, you can set the value once in the test target's `Info.plist`:

```
ReportPortalMergeGroup = $(RP_MERGE_GROUP)
```

…and pass it at build time (this survives XcodeGen if the placeholder lives in the spec):

```bash
xcodebuild build-for-testing -scheme YourScheme \
  -destination 'generic/platform=iOS' -derivedDataPath ./DerivedData \
  RP_MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
```

Xcode substitutes the build setting into the plist during the normal build. If `RP_MERGE_GROUP` is
not passed, the placeholder expands to an empty string and the agent simply emits no `merge_group`
(safe — no garbage value).

---

## Configuration Reference

### merge_group Resolution (3-tier)

Tags launches for post-run merge discovery:

| Priority | Source | When used |
|----------|--------|-----------|
| 1 | `RP_MERGE_GROUP` env var | CI/CD where env vars reach the test process (simulators, some farms) |
| 2 | `ReportPortalMergeGroup` in Info.plist | **SauceLabs real devices** (env vars blocked) — inject run-unique value at build time |
| 3 | `nil` (no attribute emitted) | Standard Xcode parallel / sequential runs |

### UUID Resolution (2-tier)

| Priority | Source | When used |
|----------|--------|-----------|
| 1 | `RP_LAUNCH_UUID` env var | CI/CD where env vars reach the process — all workers share one launch |
| 2 | Per-worker `UUID()` | Local / isolated mode (incl. SauceLabs real devices) — each worker gets its own launch, merged post-run |

### skipFinish Resolution (3-tier)

Controls whether the agent finalizes its launch or leaves it `IN_PROGRESS` for the merge script.

| Priority | Source | Value |
|----------|--------|-------|
| 1 | `RP_SKIP_FINISH` env var | `true`/`yes`/`1` vs `false`/`no`/`0` |
| 2 | `ReportPortalSkipFinish` in Info.plist | Boolean or String |
| 3 | `false` (agent finalizes normally) | **default — recommended** |

> **Recommendation: leave it unset.** If `skipFinish` is on, every device's launch stays
> `IN_PROGRESS`, and the merge script waits the full `RP_MERGE_FINALIZE_TIMEOUT` (default 120s) for
> a terminal status that never arrives before force-finishing — a guaranteed delay on every run.
> With it off, each device finalizes its own launch (already `PASSED`/`FAILED`), so the merge is
> immediate; the script's force-finish remains as a safety net.

### ci_run_id Resolution (2-tier)

Used only to disambiguate concurrent runs **when env vars reach the process** (not SauceLabs real
devices). The first non-empty value wins:

| Priority | Source |
|----------|--------|
| 1 | `RP_CI_RUN_ID` env var |
| 2 | `GITHUB_RUN_ID` env var (auto-set by GitHub Actions) |

On SauceLabs real devices env vars don't reach the process, so launches carry **no** `ci_run_id` —
that is exactly why the **merge_group must be run-unique** instead.

### Merge Script Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RP_ENDPOINT` | Yes | — | ReportPortal base URL |
| `RP_PROJECT` | Yes | — | ReportPortal project name |
| `RP_TOKEN` | Yes | — | ReportPortal API token |
| `RP_MERGE_GROUP` | Yes | — | Run-unique merge group to query (same value injected at build) |
| `RP_DISCOVER_STABLE_POLLS` | No¹ | `0` (off) | **Count-agnostic wait.** When >0, discovery re-queries until the launch count stops growing for this many consecutive polls, then merges. Best when the shard count is dynamic/unknown. |
| `RP_EXPECTED_LAUNCHES` | No¹ | — | **Precise wait.** When set, discovery re-queries until exactly this many launches appear, then merges. Use when the shard count is fixed. |
| `RP_DISCOVER_TIMEOUT` | No | `300` | Hard cap (seconds) on the wait above; after it, merge whatever was found (integer only) |
| `RP_DISCOVER_POLL` | No | `5` | Seconds between discovery re-queries (integer only) |
| `RP_CI_RUN_ID` | No | `$GITHUB_RUN_ID` | Narrows the query when present; leave unset for SauceLabs real-device runs |
| `RP_MERGE_FINALIZE_TIMEOUT` | No | `120` | Seconds to wait for in-progress launches to finalize (integer only) |
| `RP_MERGED_LAUNCH_NAME` | No | `{RP_MERGE_GROUP} (merged)` | Name for the merged launch |

> ¹ **Set one of these on SauceLabs.** Without either, discovery is a single snapshot: shards that
> finalize a moment after `saucectl run` returns aren't visible yet, so the merge silently combines
> only the launches present at that instant (the classic "merged 4 of 6"). Prefer
> `RP_DISCOVER_STABLE_POLLS` (e.g. `3`) when the device count can vary; use `RP_EXPECTED_LAUNCHES`
> when it's fixed. Both are bounded by `RP_DISCOVER_TIMEOUT`.

---

## Troubleshooting

### No launches found (merge script reports 0)

`No launches found for merge_group=… (nothing to merge)` → the script exits `0`, so an
`if: always()` merge step does **not** redden a pipeline that simply produced no launches.

Causes:
1. **merge_group didn't reach the agent.** Confirm it was injected into the test target Info.plist
   **before** the build (open a launch in ReportPortal → Attributes tab; `merge_group` must be
   present with your run-unique value).
2. **Mismatched value.** The value injected at build time must exactly equal `RP_MERGE_GROUP`
   passed to the merge script. Using `${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}` in both places makes
   them match automatically.
3. **Merge ran too early.** Ensure it runs after `saucectl run` returns (it blocks until all shards
   finish, so the next step is safe).

### Fewer launches merged than devices (e.g. "merged 4 of 6")

Two different causes — distinguish them by searching ReportPortal for the `merge_group` value:

- **All N launches exist in RP, but only some merged** → a **discovery race**: the merge queried
  once, immediately after `saucectl run`, before the last shards finalized/were indexed. **Fix:** make
  the merge step wait — set `RP_DISCOVER_STABLE_POLLS` (count-agnostic) or `RP_EXPECTED_LAUNCHES`
  (fixed count), and raise `RP_DISCOVER_TIMEOUT` if your instance is slow to index.
- **Only some launches exist in RP** → those shards never reported (device allocation failure, crash,
  or no network path to RP). Inspect the missing shards' SauceLabs console for the agent markers
  (`📡 Launch created`, `📎 merge_group`). The script merges what it finds and logs a warning; it
  does **not** fail the workflow.

### Merge API errors

- **400 "launches must have the same status":** one or more launches still `IN_PROGRESS`. The script
  polls, force-finishes, and re-checks. If finalization times out, increase
  `RP_MERGE_FINALIZE_TIMEOUT`.
- **404 on merge endpoint:** your ReportPortal is older than 5.0; the merge endpoint requires 5.0+.
- **403 Forbidden:** `RP_TOKEN` lacks merge permission in the target project.

### Code signature / install failures on real devices

If the runner installs fine but you patched the bundle: **never** modify the `.xctest` after build.
Inject `merge_group` into the source Info.plist **before** `xcodebuild` (Step 1) so the build signs
it normally.

### Network / proxy

The Ubuntu (merge) runner must reach ReportPortal. If RP is internal/VPN-only, use a self-hosted
runner or `HTTPS_PROXY` (the script honors `HTTPS_PROXY`/`https_proxy`). For custom CA certs, set
`CURL_CA_BUNDLE`. The script never uses `--insecure`. Tokens are auto-masked as `***` in logs.

---

## QA / fork-branch testing

For the end-to-end validation script (point the app at the fork branch, configure, run on ≥2 real
devices, send back evidence), see **[SAUCELABS_QA_INSTRUCTIONS.md](./SAUCELABS_QA_INSTRUCTIONS.md)**.

---

## See Also

- [GITHUB_ACTIONS_EXAMPLES.md](./GITHUB_ACTIONS_EXAMPLES.md) — Complete CI workflow
- [SAUCELABS_QA_INSTRUCTIONS.md](./SAUCELABS_QA_INSTRUCTIONS.md) — QA validation steps
- [../examples/saucectl/.sauce/config.yml](../examples/saucectl/.sauce/config.yml) — Example saucectl config
- [../README.md](../README.md) — Agent overview and configuration reference
- [../scripts/tests/](../scripts/tests/) — Self-tests for the merge script
