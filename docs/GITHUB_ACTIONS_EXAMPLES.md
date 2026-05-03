# GitHub Actions Examples for SauceLabs + ReportPortal

Complete workflow examples for merging parallel SauceLabs test results into a single ReportPortal launch.

---

## Approach A: Xctestrun UUID Injection

Injects a shared `RP_LAUNCH_UUID` into the `.xctestrun` file before uploading to SauceLabs. All devices share one launch directly. The merge step is a safety net for devices that didn't pick up the UUID.

```yaml
name: SauceLabs Regression (Approach A)

on:
  schedule:
    - cron: '0 6 * * 1-5'  # Weekdays at 6 AM
  workflow_dispatch:

env:
  RP_LAUNCH_UUID: ""  # Set dynamically in build job

jobs:
  build:
    runs-on: macos-latest
    outputs:
      rp-launch-uuid: ${{ steps.uuid.outputs.uuid }}
    steps:
      - uses: actions/checkout@v4

      - name: Build for testing
        run: |
          xcodebuild build-for-testing \
            -scheme YourScheme \
            -destination 'generic/platform=iOS' \
            -derivedDataPath ./DerivedData

      - name: Generate shared launch UUID
        id: uuid
        run: |
          UUID=$(uuidgen)
          echo "uuid=$UUID" >> "$GITHUB_OUTPUT"
          echo "Generated RP_LAUNCH_UUID: $UUID"

      - name: Inject UUID into xctestrun
        run: |
          XCTESTRUN=$(find ./DerivedData -name "*.xctestrun" | head -1)
          scripts/inject_xctestrun_env.sh "$XCTESTRUN" "${{ steps.uuid.outputs.uuid }}"

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
    runs-on: ubuntu-latest
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

      - name: Run tests on SauceLabs
        env:
          SAUCE_USERNAME: ${{ secrets.SAUCE_USERNAME }}
          SAUCE_ACCESS_KEY: ${{ secrets.SAUCE_ACCESS_KEY }}
        run: saucectl run --config .sauce/config.yml

      # Safety net: merge any launches that didn't share the UUID
      - name: Merge ReportPortal launches (safety net)
        if: always()
        env:
          RP_ENDPOINT: ${{ secrets.RP_ENDPOINT }}
          RP_PROJECT: ${{ secrets.RP_PROJECT }}
          RP_TOKEN: ${{ secrets.RP_TOKEN }}
          RP_MERGE_GROUP: "regression-${{ github.run_id }}"
          RP_CI_RUN_ID: ${{ github.run_id }}
        run: scripts/merge_rp_launches.sh
```

---

## Approach C: Post-Run Merge (Recommended)

Each device creates its own launch. The merge step combines them after all shards finish. No dependency on SauceLabs env var behavior.

**Prerequisites:** Set these in your Test Target's `Info.plist` (since env vars don't reach SauceLabs real devices):
- `ReportPortalMergeGroup` = your merge group name (e.g. `regression-nightly`)
- `ReportPortalSkipFinish` = `YES`

```yaml
name: SauceLabs Regression (Approach C)

on:
  schedule:
    - cron: '0 6 * * 1-5'
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

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
    runs-on: ubuntu-latest
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

      - name: Run tests on SauceLabs
        env:
          SAUCE_USERNAME: ${{ secrets.SAUCE_USERNAME }}
          SAUCE_ACCESS_KEY: ${{ secrets.SAUCE_ACCESS_KEY }}
        run: saucectl run --config .sauce/config.yml

      # CRITICAL: if: always() ensures merge runs even when test steps fail.
      # Without this, failed test runs won't produce a merged report for diagnosis.
      - name: Merge ReportPortal launches
        if: always()
        env:
          RP_ENDPOINT: ${{ secrets.RP_ENDPOINT }}
          RP_PROJECT: ${{ secrets.RP_PROJECT }}
          RP_TOKEN: ${{ secrets.RP_TOKEN }}
          RP_MERGE_GROUP: "regression-nightly"
          RP_CI_RUN_ID: ${{ github.run_id }}
        run: scripts/merge_rp_launches.sh
```

---

## Required GitHub Secrets

Configure these in your repository settings (Settings → Secrets and variables → Actions):

| Secret | Description | Example |
|--------|-------------|---------|
| `SAUCE_USERNAME` | SauceLabs username | `your-username` |
| `SAUCE_ACCESS_KEY` | SauceLabs access key | `abc123-def456-...` |
| `RP_ENDPOINT` | ReportPortal base URL | `https://reportportal.example.com` |
| `RP_PROJECT` | ReportPortal project name | `my_project` |
| `RP_TOKEN` | ReportPortal API token | `Bearer abc123...` |

---

## Key Design Decisions

### Why `if: always()` on the merge step?

Without `if: always()`, GitHub Actions skips subsequent steps when a previous step fails. Since test failures are expected (that's what you're testing), the merge step must run regardless. Otherwise, failed runs produce no merged report — exactly when you need one most.

### Why separate build and test jobs?

- **build** runs on `macos-latest` (required for `xcodebuild`)
- **test** runs on `ubuntu-latest` (cheaper, faster; `saucectl` and the merge script only need `curl`/`jq`)

### Why not pass env vars via saucectl?

SauceLabs `--env` flag and YAML `env:` property do **not** inject environment variables into the XCUITest process on real devices. This is a [confirmed known limitation](https://github.com/saucelabs/saucectl/issues/398). That's why Approach C uses Info.plist keys instead.

---

## See Also

- [docs/SAUCELABS_SETUP.md](./SAUCELABS_SETUP.md) — Full setup guide with configuration reference and troubleshooting
- [examples/saucectl/.sauce/config.yml](../examples/saucectl/.sauce/config.yml) — Example saucectl configuration
