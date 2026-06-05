# SauceLabs QA Validation — Post-Run Merge

End-to-end steps for QA to validate the SauceLabs merge feature on real devices and send back
actionable evidence. This **replaces** the earlier `.xctestrun` / `RP_LAUNCH_UUID` spike, which is a
dead end on SauceLabs (env vars and injected `.xctestrun` do not reach real devices — see
[SAUCELABS_SETUP.md](./SAUCELABS_SETUP.md#why-saucelabs-needs-a-special-recipe)).

> **What we're proving:** each real device creates its own ReportPortal launch tagged with a shared,
> run-unique `merge_group`; after `saucectl run` finishes, one merge step combines exactly this
> run's launches into a single launch. No env vars, no `.xctestrun` tricks.

> **Fork & branch under test:** `https://github.com/rusel95/agent-swift-XCTest.git` → branch
> `003-saucelab-integration`

---

## Step 1 — Point the app at the fork branch

Use the fork branch (not the official repo, not `main`). In an XcodeGen/`CTR.json` project, change
the `ReportPortalAgent` dependency to the fork URL + `"branch": "003-saucelab-integration"`, then
regenerate. Verify `Package.resolved` shows the **branch / commit**, not a version tag. Reset
package caches if a stale version is pinned.

## Step 2 — Remove the old Approach-A changes

If a previous attempt added them, **revert**:

- `RP_LAUNCH_UUID` in `.sauce/runner-*.yml` (`env:`) — remove it.
- The "Generate ReportPortal Launch UUID" workflow step — remove it.

They are no-ops on real devices and only cause confusion.

## Step 3 — Inject a run-unique `merge_group` BEFORE the build

In the **macOS build job**, before `xcodebuild build-for-testing`, patch the **test target's**
`Info.plist` (the one that already holds `ReportPortalURL` / `ReportPortalToken`):

```bash
MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
PLIST="<path to your UITests target Info.plist>"
/usr/libexec/PlistBuddy -c "Delete :ReportPortalMergeGroup" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :ReportPortalMergeGroup string $MERGE_GROUP" "$PLIST"
echo "Injected merge_group = $MERGE_GROUP"
```

- **Before** the build → the value is compiled in and signed normally (patching the built `.xctest`
  would break the signature on real devices).
- `${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}` is unique per run **and** per re-run.
- **Do not** set `ReportPortalSkipFinish` — let each device finalize its own launch.

> **Running by hand (no CI)?** Set a unique value manually, e.g.
> `/usr/libexec/PlistBuddy -c "Add :ReportPortalMergeGroup string qa-$(date +%s)" "$PLIST"`, and use
> that exact same value as `RP_MERGE_GROUP` in Step 5.

## Step 4 — Build and run on ≥2 real devices

```bash
xcodebuild build-for-testing -scheme YourScheme \
  -destination 'generic/platform=iOS' -derivedDataPath ./DerivedData

saucectl run --config .sauce/config.yml          # at least 2 real devices; blocks until done
```

## Step 5 — Merge (next step after saucectl, same job)

**Vendor the script once** (commit a copy into the app repo — it's a CI artifact, not shipped via
SPM): copy `scripts/merge_rp_launches.sh` into `.sauce/merge_rp_launches.sh`, keep its Apache-2.0
header, add a comment with the upstream commit SHA, and `chmod +x` it. Then:

```bash
export RP_ENDPOINT="https://<your-reportportal>"
export RP_PROJECT="<project>"
export RP_TOKEN="<token — the same one in Info.plist works>"
export RP_MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"   # SAME as Step 3

./.sauce/merge_rp_launches.sh 2>&1 | tee merge.log
```

> Spike only (never for scheduled runs): you may `curl` the script from a **pinned commit SHA**
> (not a branch) for a one-off manual test. Don't `curl`-at-runtime in CI — it executes unpinned
> remote code every run.

In CI, add `RP_TOKEN` (and `RP_ENDPOINT`/`RP_PROJECT`) as repository secrets
(**Settings → Secrets and variables → Actions**) and reference them via `${{ secrets.* }}`.

## Step 6 — Verify in ReportPortal

| Check | Expected |
|-------|----------|
| One launch per device exists | each tagged with your `merge_group` (Attributes tab) |
| Each launch's status before merge | `PASSED` / `FAILED` (device finalized its own launch) |
| Merge script output | `Merged launch: <URL>` |
| Merged launch | single launch; test count = sum across devices |

## Step 7 — Evidence to send back

1. **`merge.log`** — full stdout+stderr of the merge step (token is auto-masked as `***`).
2. **ReportPortal screenshots:** a per-device launch **Attributes** tab (showing `merge_group`) and
   the final **merged** launch.
3. **Device / OS** of each shard, and how many launches existed before merge vs. expected.
4. **SauceLabs console** for one device (agent markers: `🎬` launch start, `📡` launch created,
   `📎` merge_group, `🏁` bundle finished).
5. Anything unexpected (paste the `merge.log` tail on failure).

---

## Common gotchas

- **0 launches found:** `merge_group` wasn't injected before build, or the merge-step value differs
  from the build-step value. Check a launch's Attributes tab.
- **Install/signature failure:** something patched the built bundle after signing — inject into the
  **source** Info.plist before build instead.
- **Merge step can't reach RP:** the Ubuntu runner has no network path to ReportPortal (internal /
  VPN). Run the merge where RP is reachable, or set `HTTPS_PROXY`.
- **403 on merge:** the token lacks merge permission; **404 on merge:** ReportPortal older than 5.0.
