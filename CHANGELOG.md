# Changelog

## [Unreleased]

## [4.0.0] - 2025-11-04
### ⚠️ BREAKING CHANGES
This is a major version with breaking changes. See [migration guide](docs/migration-from-filelock.md) for upgrade instructions.

#### Changed
- **Coordination System**: Replaced POSIX file lock coordination with hybrid approach (UUID + file-based)
- **Minimum Requirements**: Swift 5.5+, iOS 13+ (requires Swift Concurrency runtime)
- **Architecture**: Migrated to async/await and Actor model for thread-safe coordination
- **API Signatures**: 
  - `ReportingService.startLaunchV2()` now accepts optional `uuid` parameter
  - `ReportingService.finalizeLaunchV2()` signature changed (added coordination parameters)

#### Removed
- ❌ `LaunchCoordinator.swift` - Replaced by UUID-based coordination
- ❌ `LaunchIdLock.swift` - POSIX flock wrapper no longer needed
- ❌ Environment variable `RP_LAUNCH_LOCK_FILE` - No longer used
- ❌ Tolerant 404/409 finish handling - Replaced by single finish coordination

#### Added
- ✅ **UUID-based Launch Coordination**: Uses ReportPortal v2 API with 409 Conflict handling
  - Works on both simulators and real devices
  - Eliminates POSIX file lock dependency
  - Automatic UUID generation (PGID-based) or custom via `RP_LAUNCH_UUID`
- ✅ **File-based Suite Coordination** (simulators only):
  - Prevents duplicate suites across parallel workers
  - Scales to 100+ test classes efficiently
  - Uses POSIX flock() with 10s timeout and exponential backoff
- ✅ **File-based Finish Coordination** (simulators only):
  - Single finish API call instead of multiple attempts
  - Correct status aggregation: FAILED > STOPPED > SKIPPED > PASSED
  - Last worker detection with atomic operations
- ✅ **Platform Detection**: Automatic simulator vs real device detection
- ✅ **Configuration Validation**: 
  - UUID format validation (RFC 4122)
  - Platform capability logging
  - Directory writability checks
- ✅ **Enhanced Error Handling**:
  - All errors logged with `[ERROR]` prefix for filtering
  - Sentry integration for distributed logging
  - Correlation IDs for debugging parallel execution
- ✅ **Comprehensive Logging**:
  - Launch UUID source (environment vs auto-generated)
  - Worker registration and lifecycle tracking
  - Suite coordination path (file-based vs direct API)
  - Finish coordination decision (last worker detection)
- ✅ **Automatic Cleanup**: All coordination files removed after test run

#### Added (New Files)
- `Sources/Utilities/FileCoordination.swift` - POSIX flock wrapper for suite/finish coordination
- `Sources/Entities/SuiteCoordinator.swift` - File-based suite deduplication (Actor)
- `Sources/Entities/WorkerTracker.swift` - Worker lifecycle tracking (Actor)
- `Sources/Entities/FinishCoordinator.swift` - Single finish with status aggregation (Actor)
- `Sources/Utilities/Logger.swift` - Enhanced with correlation ID support and Sentry integration
- `ExampleUnitTests/EndToEndCoordinationTests.swift` - Integration tests for hybrid coordination
- `docs/migration-from-filelock.md` - Migration guide from v3.x to v4.0

#### Fixed
- **Parallel Testing Issues**:
  - Fixed multiple launches created by parallel workers (now exactly 1)
  - Fixed duplicate suites (e.g., 50 suites instead of 10) on simulators
  - Fixed multiple finish API calls with incorrect status
  - Fixed race conditions in suite creation
- **Real Device Support**:
  - Launch coordination now works on real devices (UUID-based)
  - Suite/finish coordination gracefully falls back to direct API calls
- **Resource Management**:
  - Fixed leftover lock files in /tmp
  - All coordination files now cleaned up automatically

### Performance Improvements
- Suite coordination scales to 100+ test classes with constant overhead
- File-based deduplication faster than API-based duplicate checking
- Exponential backoff prevents lock contention (100ms-1600ms)

### Documentation
- Added [migration guide](docs/migration-from-filelock.md) for v3.x → v4.0 upgrade
- Updated [pre-action script setup](docs/xcode-pre-action-setup.md) with UUID configuration
- Updated README.md with hybrid coordination explanation

### Migration Notes
For most users on **simulators**: No action required! The new coordination is backward compatible.

For **CI/CD pipelines**: Set `RP_LAUNCH_UUID=$(uuidgen)` in pre-action script for guaranteed single launch.

For **real devices**: Launch coordination works, but suite/finish coordination has limited support (see migration guide).

See [migration guide](docs/migration-from-filelock.md) for complete details.

---

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
