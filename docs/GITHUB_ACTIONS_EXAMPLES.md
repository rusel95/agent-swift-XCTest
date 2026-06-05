# GitHub Actions Examples for SauceLabs + ReportPortal

How to merge parallel SauceLabs XCUITest results into a **single** ReportPortal launch.

---

## TL;DR — why this needs a specific recipe

On SauceLabs **real devices**:

1. Environment variables never reach the XCUITest process — neither `--env` nor YAML `env:`
   ([saucectl #398](https://github.com/saucelabs/saucectl/issues/398), "Virtual Devices Only").
2. SauceLabs **regenerates its own `.xctestrun`** from the uploaded `.ipa + .ipa`, so anything
   injected into the build's `.xctestrun` is discarded (you'll see `XCTestRun Config File = null`
   in the job metadata).

The **only** configuration that survives to the device is what is **compiled into the test
bundle's `Info.plist` at build time**. So the working pattern is:

1. **Before** building, inject a **run-unique** `ReportPortalMergeGroup` into the test target's
   `Info.plist` (compiled in and signed as part of the normal build — no re-sign).
2. Run on SauceLabs. `saucectl run` **blocks** until all shards finish.
3. **After** `saucectl run`, in the same job, run the merge script with the **same** merge-group
   value. It finds exactly this run's launches and merges them.

Each device still creates its own launch — but they all carry the same `merge_group` attribute, so
the merge script can pick out exactly the ones from this run. Do **not** rely on `RP_LAUNCH_UUID`
or `--env` on real devices.

---

## Canonical workflow

```yaml
name: SauceLabs Regression

on:
  schedule:
    - cron: '0 6 * * 1-5'   # weekdays at 6 AM
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-latest          # xcodebuild requires macOS
    steps:
      - uses: actions/checkout@v4

      # If you use XcodeGen, generate the project first:
      # - name: Generate project
      #   run: xcodegen generate

      # ── Inject a RUN-UNIQUE merge_group into the test target's Info.plist ──
      # This MUST happen BEFORE xcodebuild so the value is compiled in and signed
      # normally. Patching the built/signed .xctest would invalidate the signature
      # and the runner would not install on a real device.
      - name: Inject run-unique merge_group (pre-build)
        run: |
          MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
          PLIST="ExampleUITests/Info.plist"     # ← your test target's INFOPLIST_FILE
          /usr/libexec/PlistBuddy -c "Delete :ReportPortalMergeGroup" "$PLIST" 2>/dev/null || true
          /usr/libexec/PlistBuddy -c "Add :ReportPortalMergeGroup string $MERGE_GROUP" "$PLIST"
          echo "Injected merge_group = $MERGE_GROUP"

      - name: Build for testing
        run: |
          xcodebuild build-for-testing \
            -scheme YourScheme \
            -destination 'generic/platform=iOS' \
            -derivedDataPath ./DerivedData

      - name: Package artifacts
        run: |
          mkdir -p ./build
          cp $(find ./DerivedData -name "*.ipa" | head -1) ./build/Example.ipa
          cp $(find ./DerivedData -name "*-Runner.ipa" | head -1) ./build/ExampleUITests-Runner.ipa

      - name: Upload build artifacts
        uses: actions/upload-artifact@v4
        with:
          name: test-artifacts
          path: build/

  test:
    runs-on: ubuntu-latest         # saucectl + merge script only need curl/jq
    needs: build
    steps:
      - uses: actions/checkout@v4

      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          name: test-artifacts
          path: build/

      - name: Install saucectl
        run: npm i -g saucectl

      - name: Run tests on SauceLabs       # blocks until ALL shards finish
        env:
          SAUCE_USERNAME: ${{ secrets.SAUCE_USERNAME }}
          SAUCE_ACCESS_KEY: ${{ secrets.SAUCE_ACCESS_KEY }}
        run: saucectl run --config .sauce/config.yml

      # if: always() → merge runs even when tests fail (failures are expected).
      # Same merge_group value as the build job (run_id + run_attempt match across jobs).
      - name: Merge ReportPortal launches
        if: always()
        env:
          RP_ENDPOINT: ${{ secrets.RP_ENDPOINT }}
          RP_PROJECT:  ${{ secrets.RP_PROJECT }}
          RP_TOKEN:    ${{ secrets.RP_TOKEN }}
          RP_MERGE_GROUP: regression-${{ github.run_id }}-${{ github.run_attempt }}
          RP_EXPECTED_LAUNCHES: "6"   # your device/shard count — wait for ALL before merging
        run: scripts/merge_rp_launches.sh
```

> **Vendor `merge_rp_launches.sh` into your repo.** Commit a copy (e.g. at
> `scripts/merge_rp_launches.sh` or `.sauce/merge_rp_launches.sh`) and call that local path, as
> the workflow above does. The script is a **CI artifact, not delivered via Swift Package Manager**
> (SPM ships library code, not files to your CI filesystem), so a local copy is required even after
> the agent is officially released. Keep its Apache-2.0 header and add a comment noting the upstream
> commit you copied from, so you can re-sync later.
>
> Do **not** `curl … | sh` it from a branch at runtime in production — that executes unpinned code
> from a remote repo on every run (fragile if the branch moves/disappears, and a CI supply-chain
> risk). A one-off `curl … -o merge.sh` pinned to a **commit SHA** is acceptable only for a
> throwaway spike, never for scheduled runs.

---

## Key design decisions

### Why a run-unique merge group?

`regression-${{ github.run_id }}-${{ github.run_attempt }}`:

- `run_id` is **identical across every job** of one workflow run, so the build job and the merge
  job agree on the value automatically — nothing needs to be passed between them.
- `run_attempt` increments on a **re-run** (which keeps the same `run_id`), so a re-run does not
  collide with the original run's launches.

A static value like `regression-nightly` is unsafe: two runs in the same day (or a re-run) would
merge each other's launches. Because env vars don't reach the device, the launches carry
`merge_group` but **not** `ci_run_id`, so the merge group itself must be the unique key.

### Why inject into `Info.plist` *before* build (not after)?

Patching the built/signed `.xctest` invalidates the code signature → the test runner won't install
on a real device. Injecting into the **source** `Info.plist` before `xcodebuild` means the value is
compiled in and signed as part of the normal build.

**Alternative (Xcode-native):** put `ReportPortalMergeGroup = $(RP_MERGE_GROUP)` in the test
target's `Info.plist` once (survives XcodeGen if it's in the spec), then build with
`xcodebuild build-for-testing … RP_MERGE_GROUP="regression-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"`.
Xcode substitutes the build setting into the plist during the normal build.

### Why **not** set `ReportPortalSkipFinish=YES`?

`skipFinish` keeps each device's launch `IN_PROGRESS` (it delegates finalization to the merge
script). But the merge script then waits the full `RP_MERGE_FINALIZE_TIMEOUT` (default 120s) for a
terminal status that never comes, before force-finishing. For a first working integration, **don't
set it** — let each device finalize its own launch (so launches are already `PASSED`/`FAILED`), and
the merge is immediate. The script's force-finish stays as a safety net for stragglers.

### Why two jobs (`macos-latest` + `ubuntu-latest`)?

This is just how GitHub Actions works — each **job** runs on a **runner**, and you choose the OS:

- **build** must be on macOS, because `xcodebuild` only runs there.
- **test** runs on Ubuntu because `saucectl` is just a CLI that talks to the SauceLabs cloud (the
  actual devices are in SauceLabs, not on the runner), and the merge script only needs `curl`/`jq`.
  Ubuntu runners are cheaper and faster than macOS ones.

You *could* run everything on macOS; splitting is a cost/speed optimization, not a requirement.
Both jobs are in the **same workflow run**, so they share the same `github.run_id`.

### Required GitHub secrets

| Secret | Description | Example |
|--------|-------------|---------|
| `SAUCE_USERNAME` | SauceLabs username | `your-username` |
| `SAUCE_ACCESS_KEY` | SauceLabs access key | `abc123-def456-…` |
| `RP_ENDPOINT` | ReportPortal base URL | `https://reportportal.example.com` |
| `RP_PROJECT` | ReportPortal project name | `my_project` |
| `RP_TOKEN` | ReportPortal API token (no `Bearer` prefix) — the same token you put in `Info.plist` works | `abc123…` |

> The Ubuntu runner must be able to **reach your ReportPortal over the network**. If RP is internal
> (behind a VPN), a GitHub-hosted runner cannot reach it — use a self-hosted runner or set
> `HTTPS_PROXY`.

---

## See Also

- [docs/SAUCELABS_SETUP.md](./SAUCELABS_SETUP.md) — Full setup guide, configuration reference, troubleshooting
- [docs/SAUCELABS_QA_INSTRUCTIONS.md](./SAUCELABS_QA_INSTRUCTIONS.md) — Step-by-step for QA validating the fork branch
- [examples/saucectl/.sauce/config.yml](../examples/saucectl/.sauce/config.yml) — Example saucectl configuration
