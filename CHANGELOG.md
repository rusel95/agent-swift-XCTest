# Changelog

## [Unreleased]

## [4.1.0] - 2026-06-09

### Fixed
- Launch gate eliminates the actor priority inversion that caused some parallel
  shards to lose all attributes ("merged 4 of 6"). Suites/tests now await a single
  launch-creation Task and skip reporting when launch creation ultimately fails,
  by @rusel95.
- Launch finalization treats only HTTP 409 (already finished) as non-fatal; every
  other HTTP status and non-HTTP error now propagates, by @rusel95.

### Added
- SauceLabs real-device merge support: `RP_MERGE_GROUP` / `ReportPortalMergeGroup`
  (`merge_group` attribute), `RP_SKIP_FINISH` / `ReportPortalSkipFinish` (defer
  finalization to a post-run merge script), and `RP_CI_RUN_ID` / `GITHUB_RUN_ID`
  (`ci_run_id` attribute to disambiguate concurrent CI runs), by @rusel95.
- Launch creation retries up to 3 times with exponential backoff on transient
  errors, by @rusel95.
- `docs/SAUCELABS_SETUP.md` — self-contained guide for the SauceLabs real-device
  merge: setup steps, the vendorable merge script, a GitHub Actions workflow, and a
  copy-paste prompt for wiring it into a consuming repo with an AI agent, by @rusel95.

### Changed
- `LaunchManager` actor replaced by a caseless `LaunchUUID` enum that resolves the
  per-process launch UUID once (`RP_LAUNCH_UUID` env var or auto-generated), by @rusel95.
- CocoaPod deployment targets lowered to the library's actual floor — iOS 15 /
  macOS 12 / tvOS 15 — to match `Package.swift`. The podspec previously
  over-declared iOS 18.6 / macOS 14.0 / tvOS 18.2, by @rusel95.

### Removed
- Unused `GetCurrentLaunchEndPoint` (dead after the V2 API migration), by @rusel95.

## [4.0.1] - 2025-12-12

## [4.0.0] - 2025-11-21

### Changed
- **BREAKING**: LaunchManager simplified from Actor to simple singleton class, by @rusel95
  - Changed from ~180 lines to 26 lines (85% reduction)
  - Removed bundle counting (activeBundleCount, increment/decrement methods)
  - Removed status aggregation (updateStatus, getAggregatedStatus methods)
  - Removed finalization tracking (isFinalized, markFinalized methods)
  - Launch ID now lazy var with custom UUID generation (no API waiting)
  - Direct property access: `LaunchManager.shared.launchID` instead of async methods
- Custom UUID Strategy: Generate launch UUID client-side instead of waiting for API response, by @rusel95
  - Eliminates race conditions, timeout logic, and complex synchronization
  - UUID immediately available for all test operations
  - ReportPortal launch creation happens asynchronously in background
- Removed redundant status tracking - ReportPortal server calculates final status, by @rusel95
- Single bundle execution model (no multi-bundle coordination), by @rusel95

## [3.1.3] - 2025-09-11
### Added
- Enhanced error messages with metadata (device info, timestamps, test context), by @rusel95
### Fixed
- Missing Line Numbers in Error Messages, by @rusel95
- Dynamic Suite Naming Not Working, by @rusel95

## [3.1.2] - 2025-08-07

## [3.1.1] - 2025-07-18
### Fixed
- Attachments to log entries, by @rusel95

## [3.1.0] - 2025-06-25
### Fixed
- [Issue #10](https://github.com/reportportal/agent-swift-XCTest/issues/10): Integrate reportportal with XCUItests, by @rusel95
- [Issue #11](https://github.com/reportportal/agent-swift-XCTest/issues/11): testSuiteIdNotFound Issue, by @rusel95

## [3.0.4] - 2025-04-11
### Fixed
- [Issue #13](https://github.com/reportportal/agent-swift-XCTest/issues/13): TypeMismatch for startTime endTime lastModified, by @rusel95

## [3.0.3] - 2024-11-12
### Fixed
- [Issue #8](https://github.com/reportportal/agent-swift-XCTest/issues/8): Failed tests don't show exception logs in ReportPortal, by @YauheniPo

## [3.0.2] - 2024-04-30

## [3.0.2] - 2024-04-30

### Added
- Validation and Release flows

### Updated
- Update podspec manifest

## [2.4.0]
### Added
- Client version updated
