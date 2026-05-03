# Approach A Spike: xctestrun Environment Variable Injection

## Goal

Validate that environment variables injected into `.xctestrun` files are readable by XCUITests running on SauceLabs real devices / simulators.

## 1. Build the IPA and xctestrun

```bash
# Build for testing (produces .xctestrun + test artifacts)
xcodebuild build-for-testing \
  -project ReportPortalAgent.xcodeproj \
  -scheme ReportPortalAgent \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build

# Locate artifacts
XCTESTRUN=$(find build -name '*.xctestrun' -print -quit)
echo "xctestrun: $XCTESTRUN"
```

For real devices, use `generic/platform=iOS` and archive to `.ipa`.

## 2. Inject Environment Variables

```bash
# Inject all required RP env vars
./scripts/inject_xctestrun_env.sh "$XCTESTRUN" RP_VALIDATION_TOKEN "spike-$(date +%s)"
./scripts/inject_xctestrun_env.sh "$XCTESTRUN" RP_LAUNCH_UUID "$(uuidgen)"
./scripts/inject_xctestrun_env.sh "$XCTESTRUN" RP_MERGE_GROUP "spike-group"
./scripts/inject_xctestrun_env.sh "$XCTESTRUN" RP_SKIP_FINISH "true"

# Verify (optional)
/usr/libexec/PlistBuddy -c "Print" "$XCTESTRUN" | grep -A1 EnvironmentVariables
```

## 3. Run on SauceLabs

### Option A: saucectl

Create `.sauce/config.yml`:

```yaml
apiVersion: v1alpha
kind: xcuitest
sauce:
  region: us-west-1
xcuitest:
  app: build/Build/Products/Debug-iphonesimulator/ReportPortalAgent.app
  testApp: build/Build/Products/Debug-iphonesimulator/ExampleUITests-Runner.app
  otherApps: []
suites:
  - name: "spike-env-injection"
    devices:
      - name: "iPhone.*"
        platformVersion: "17"
    testOptions:
      class: SauceLabsValidationTest/testEnvironmentVariableInjection
```

```bash
saucectl run
```

### Option B: SauceLabs REST API

```bash
# Upload app + test runner, then create test run with the xctestrun
# See: https://docs.saucelabs.com/dev/api/storage/
```

## 4. Inspect Results

### Test Attachments
- SauceLabs UI → Test Results → select test → Artifacts tab
- Look for `environment_variables` attachment containing key=value pairs

### Console Logs
- SauceLabs UI → Test Results → Console Output
- Search for `🔍 ENV[` lines

### xcresult Bundle
```bash
# If xcresult is downloadable from SauceLabs:
xcrun xcresulttool get --path TestResults.xcresult --format json
```

## 5. Expected Outcomes

### ✅ Viable (Approach A works)
- `RP_VALIDATION_TOKEN` shows the injected value (not `<NOT SET>`)
- `RP_LAUNCH_UUID` shows the injected UUID
- All 4 env vars are present in the test attachment

### ❌ Not Viable (Approach A fails)
- All env vars show `<NOT SET>` → SauceLabs strips/ignores xctestrun EnvironmentVariables
- Some vars present, some missing → Partial support, needs investigation
- Test doesn't run → xctestrun format incompatible with SauceLabs runner

### If Not Viable
Fall back to Approach B (Info.plist injection) or Approach C (file-based coordination). See `docs/SAUCELABS_FEASIBILITY_ANALYSIS.md`.
