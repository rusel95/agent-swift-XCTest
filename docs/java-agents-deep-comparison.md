# Deep Comparison: ReportPortal Java Agents vs Swift XCTest Agent

## Executive Summary

After extensive research of the Java client and Cucumber agent implementations, here's what I found:

**YES** - Java agents have sophisticated multi-process coordination, but implemented **VERY differently** from our Swift solution.

**Key Finding:** Java uses **TWO coordination modes** (FILE + SOCKET), while our Swift implementation uses **file-based only**. However, our approach has **critical advantages** for the iOS/macOS ecosystem.

---

## 1. Java Agent Architecture Overview

### 1.1 Core Coordination Strategy

Java agents (`client-java` + `agent-java-cucumber7`) use:

```
┌─────────────────────────────────────────────────────┐
│  Multi-Process Launch Coordination (client-java)    │
├─────────────────────────────────────────────────────┤
│  Mode 1: FILE-based (LaunchIdLockFile)             │
│  Mode 2: SOCKET-based (LaunchIdLockSocket)         │
│  Default: FILE mode                                  │
└─────────────────────────────────────────────────────┘
```

**Configuration:**
```properties
rp.client.join=true                    # Enable multi-process mode
rp.client.join.mode=FILE               # FILE or SOCKET
rp.client.join.port=25464              # Socket port (if SOCKET mode)
rp.client.join.timeout.value=1800000   # 30 min timeout
```

### 1.2 File Lock Implementation (LaunchIdLockFile.java)

**Location:** `src/main/java/com/epam/reportportal/service/launch/lock/LaunchIdLockFile.java`

**Mechanism:**
```java
public class LaunchIdLockFile extends AbstractLaunchIdLock {
    private static volatile Pair<RandomAccessFile, FileLock> mainLock;
    private static volatile String lockUuid;
    
    // TWO files used:
    // 1. .lock file - Java FileLock (exclusive lock)
    // 2. .sync file - Worker registry with timestamps
    
    @Override
    public String obtainLaunchUuid(@Nonnull final String instanceUuid) {
        // Try to acquire .lock file
        Pair<RandomAccessFile, FileLock> syncLock = obtainLock(syncFile);
        if (syncLock != null) {
            if (mainLock == null) {
                Pair<RandomAccessFile, FileLock> lock = obtainLock(lockFile);
                if (lock != null) {
                    // PRIMARY worker - acquired lock!
                    lockUuid = instanceUuid;
                    mainLock = lock;
                    writeLaunchUuid(syncLock);
                    return instanceUuid;
                } else {
                    // SECONDARY worker - read UUID from primary
                    executeOperation(new LaunchRead(instanceUuid), syncLock);
                }
            }
        }
        return obtainLaunch(instanceUuid);
    }
}
```

**Key Details:**
- Uses `RandomAccessFile` + `FileLock` (Java NIO)
- **Blocking I/O** with retry/timeout mechanism
- Two-file approach:
  - `.lock` file: Exclusive lock holder
  - `.sync` file: Worker registry with timestamps
- Timestamp-based staleness detection (30 min default)
- Automatic cleanup when last worker finishes

**File Format (.sync file):**
```
1699281234567:worker-uuid-1
1699281234789:worker-uuid-2
1699281235012:worker-uuid-3
```

### 1.3 Socket Implementation (LaunchIdLockSocket.java)

**Location:** `src/main/java/com/epam/reportportal/service/launch/lock/LaunchIdLockSocket.java`

**Mechanism:**
```java
public class LaunchIdLockSocket extends AbstractLaunchIdLock {
    private static volatile ServerSocket mainLock;
    private static volatile String lockUuid;
    
    @Override
    public String obtainLaunchUuid(@Nonnull final String uuid) {
        if (mainLock == null) {
            try {
                // Try to bind to port (PRIMARY worker)
                mainLock = new ServerSocket(portNumber, SOCKET_BACKLOG, 
                                           InetAddress.getLocalHost());
                lockUuid = uuid;
                // Start server thread
                handler = new ServerHandler();
                handler.start();
                return uuid;
            } catch (IOException e) {
                // Port already bound - connect as SECONDARY worker
                return writeInstanceUuid(uuid);
            }
        } else {
            // Another worker already owns socket
            return writeInstanceUuid(uuid);
        }
    }
}
```

**Server Thread:**
```java
private static class ServerHandler extends Thread {
    @Override
    public void run() {
        while (running) {
            Socket s = mainLock.accept();
            // Send launch UUID to connecting worker
            os.write(lockUuid.getBytes(TRANSFER_CHARSET));
            os.flush();
            
            // Receive worker registration
            byte[] updateUuid = new byte[...];
            is.readFully(updateUuid);
            
            // Register worker with timestamp
            INSTANCES.put(instanceUuid, new Date());
        }
    }
}
```

**Why Socket Mode Exists:**
- **Faster** than file locking (network I/O < disk I/O)
- **More reliable** on network file systems (NFS, SMB)
- **Better for containers** (Docker/Kubernetes)
- **Cross-platform consistency**

---

## 2. Worker Coordination Flow

### 2.1 Java Flow (Primary + Secondary Workers)

```
Worker 1 (PRIMARY):
├─ 1. Call obtainLaunchUuid(uuid1)
├─ 2. Try acquire .lock file → SUCCESS
├─ 3. Write uuid1 to .lock and .sync files
├─ 4. Start launch via API
├─ 5. Hold .lock file until finish
└─ 6. finishInstanceUuid(uuid1) → cleanup

Worker 2 (SECONDARY):
├─ 1. Call obtainLaunchUuid(uuid2)
├─ 2. Try acquire .lock file → FAIL (worker 1 has it)
├─ 3. Read launch UUID from .sync file → uuid1
├─ 4. Write uuid2 to .sync file (register self)
├─ 5. Skip launch API (join existing)
└─ 6. finishInstanceUuid(uuid2) → remove from .sync

Worker 3 (SECONDARY):
├─ 1. Call obtainLaunchUuid(uuid3)
├─ 2. Read launch UUID → uuid1
├─ 3. Register uuid3 in .sync
└─ 4. Join existing launch
```

### 2.2 Launch Finalization Logic

**Primary Worker Wait Strategy:**
```java
// Primary worker waits for all secondary workers
public void finishLaunch() {
    // Get list of live workers from .sync file
    Collection<String> liveWorkers = getLiveInstanceUuids();
    
    while (!liveWorkers.isEmpty()) {
        // Wait for timeout (default 30 min)
        Thread.sleep(1000);
        liveWorkers = getLiveInstanceUuids();
    }
    
    // All workers done - finalize launch
    client.finishLaunch(launchId, status);
}
```

**Timestamp-based Liveness:**
```java
public Collection<String> getLiveInstanceUuids() {
    long timeoutTime = System.currentTimeMillis() - fileWaitTimeout;
    
    return readSyncFile()
        .stream()
        .filter(record -> record.timestamp > timeoutTime)
        .map(record -> record.uuid)
        .collect(Collectors.toSet());
}
```

---

## 3. Swift Agent Architecture (Our Implementation)

### 3.1 Core Strategy

```
┌─────────────────────────────────────────────────────┐
│  Swift XCTest Agent Coordination                    │
├─────────────────────────────────────────────────────┤
│  Mode: FILE-based only (LaunchManager)              │
│  Mechanism: Swift Concurrency (Actor + async/await) │
│  Coordination: UUID file + API 409 handling         │
└─────────────────────────────────────────────────────┘
```

**File Location:** `Sources/Entities/LaunchManager.swift`

### 3.2 UUID Coordination

```swift
actor LaunchManager {
    private var launchUUID: String?
    private var launchID: String?
    
    func getOrCreateLaunchUUID() -> String {
        // Priority 1: Environment variable (CI/CD)
        if let envUUID = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"] {
            return envUUID
        }
        
        // Priority 2: File-based (local Xcode)
        let syncFilePath = "/tmp/reportportal/launch_uuid.txt"
        
        if let existingUUID = try? String(contentsOfFile: syncFilePath) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: syncFilePath)
            let modDate = attrs?[.modificationDate] as? Date
            let ageInSeconds = -modDate.timeIntervalSinceNow
            
            if ageInSeconds > 10 { // 10 seconds - stale check
                // Old run - create fresh UUID
                try? FileManager.default.removeItem(atPath: syncFilePath)
            } else {
                // Same run - reuse UUID
                return existingUUID
            }
        }
        
        // First worker - create UUID
        let newUUID = UUID().uuidString
        try? newUUID.write(toFile: syncFilePath, atomically: true, encoding: .utf8)
        return newUUID
    }
}
```

### 3.3 Launch API Coordination (409 Handling)

**Our Unique Approach:**
```swift
func startLaunch(uuid: String) async throws -> String {
    let endPoint = StartLaunchV2EndPoint(uuid: uuid, ...)
    
    do {
        let result = try await httpClientV2.callEndPoint(endPoint)
        print("✅ Created launch: \(result.id)")
        return result.id
    } catch let error as HTTPClientError {
        if case .httpError(409, let body) = error {
            // 409 Conflict - launch already created by another worker!
            print("⚡️ 409 Conflict - joining existing launch")
            
            // Extract launch ID from error response
            if let json = parseJSON(body), let launchID = json["id"] {
                return launchID  // Join existing
            }
            
            // Fallback: use UUID as ID
            return uuid
        }
        throw error
    }
}
```

**Why This Works:**
- ReportPortal API is **idempotent** for launch creation with same UUID
- First worker: `POST /launch` with UUID → 201 Created
- Second worker: `POST /launch` with same UUID → **409 Conflict** (but includes launch ID!)
- Third+ workers: Same 409 handling

---

## 4. Critical Differences

| Feature | Java (FILE mode) | Java (SOCKET mode) | Swift (Our Solution) |
|---------|------------------|-------------------|----------------------|
| **Lock Mechanism** | Java FileLock | ServerSocket bind | No explicit lock |
| **Worker Registry** | .sync file (timestamp) | In-memory Map | No registry |
| **Staleness Detection** | 30 min timeout | Heartbeat updates | 10 sec file age |
| **Primary Worker Selection** | First to acquire lock | First to bind port | First to call API |
| **Secondary Worker Discovery** | Read .sync file | Connect to socket | API 409 response |
| **Launch Finalization** | Primary waits for workers | Primary waits for workers | **Tolerant (all try, 409 is OK)** |
| **File I/O** | Blocking (RandomAccessFile) | None | Non-blocking (String write) |
| **Concurrency Model** | Java synchronized | Thread-based server | Swift Actor (async/await) |
| **Cross-Process** | ✅ Yes | ✅ Yes | ✅ Yes (via file) |
| **Cross-Machine** | ❌ No (local files) | ❌ No (localhost socket) | ❌ No (local files) |

---

## 5. Architectural Decisions: Why We Differ

### 5.1 Why Java Uses Two Mechanisms

**FILE mode:**
- Traditional, well-tested
- Works on all platforms
- Simple to implement

**SOCKET mode:**
- **Network file systems** (NFS, SMB) have unreliable file locking
- **Container environments** (Docker, K8s) - file locks don't work across containers
- **Performance** - socket I/O faster than disk I/O on some systems

**Java's Problem:**
```
Jenkins Server (CI/CD):
├─ Worker 1 (container A) - /tmp/lock file
├─ Worker 2 (container B) - /tmp/lock file (different /tmp!)
└─ Result: Both think they're primary ❌
```

**Java's Solution:**
```
Jenkins Server:
├─ Worker 1 → Connect to localhost:25464 → SUCCESS (primary)
├─ Worker 2 → Connect to localhost:25464 → FAIL (secondary)
└─ Result: Correct coordination ✅
```

### 5.2 Why Swift Uses Single FILE Mechanism

**iOS/macOS Ecosystem Constraints:**

1. **No Cross-Container Tests**
   - Xcode doesn't run tests in separate containers
   - All test processes share same `/tmp` directory
   - File locking **IS** reliable

2. **Socket Binding Restrictions**
   - iOS/macOS sandbox restrictions
   - Network entitlements required
   - Complexity not justified

3. **Swift Concurrency**
   - Actor model provides **safe** concurrent access
   - No need for Java-style synchronized blocks
   - async/await eliminates callback hell

4. **API-First Design**
   - ReportPortal API **itself** provides coordination via 409
   - UUID uniqueness guaranteed by API
   - No need for complex lock files

**Our Advantage:**
```swift
// Java: Complex lock file management
RandomAccessFile lock = new RandomAccessFile(file, "rwd");
FileLock fileLock = lock.getChannel().tryLock();
// Write UUID with timestamp
// Update heartbeat every N seconds
// Clean up on finish

// Swift: Simple file write
try UUID().uuidString.write(toFile: path, atomically: true, encoding: .utf8)
// API handles the rest via 409!
```

---

## 6. Tolerant Finalization Strategy

### 6.1 Java Approach (Coordinated Finalization)

**Primary Worker Responsibility:**
```java
public void finish() {
    if (isPrimaryWorker) {
        // Wait for all secondary workers
        Collection<String> workers = getLiveInstanceUuids();
        while (!workers.isEmpty()) {
            Thread.sleep(1000);
            workers = getLiveInstanceUuids();
        }
        
        // Aggregate statuses from all workers
        TestStatus status = aggregateStatuses();
        
        // ONLY primary calls finish API
        client.finishLaunch(launchId, status);
    } else {
        // Secondary workers: just mark themselves done
        finishInstanceUuid(myUuid);
    }
}
```

**Pros:**
- ✅ **Single finish call** - clean API usage
- ✅ **Correct status aggregation** - knows all worker statuses
- ✅ **Guaranteed order** - launch finishes after all items

**Cons:**
- ❌ **Primary must wait** - can delay test completion
- ❌ **Timeout risk** - if secondary worker hangs, primary waits 30min
- ❌ **Complex coordination** - heartbeat, timestamp management

### 6.2 Swift Approach (Tolerant Finalization)

**All Workers Try, 409 is OK:**
```swift
func finishLaunch() async {
    // Every worker tries to finish
    do {
        try await reportingService.finalizeLaunch(launchID, status)
        print("✅ Successfully finalized launch")
    } catch let error as HTTPClientError {
        if case .httpError(409, _) = error {
            // Another worker already finished - THAT'S OK!
            print("ℹ️ Launch already finalized (409)")
        } else {
            throw error
        }
    }
}
```

**Pros:**
- ✅ **No waiting** - workers finish independently
- ✅ **Simple** - no coordination files needed
- ✅ **Fast** - first worker to finish wins
- ✅ **Resilient** - if one worker fails, others can finish

**Cons:**
- ❌ **Multiple API calls** - some get 409 (but that's intentional)
- ❌ **Status might not be final** - first finisher sets status
- ❌ **Requires API support** - ReportPortal must handle 409

**Why This Works for Us:**
- ReportPortal API is **idempotent** for finish
- Test suite count is tracked by `SuiteCounterCoordinator` (file-based)
- Workers only try to finish when **all suites done**
- First to finish sets status, others get 409 and move on

---

## 7. What Java Does Better

### 7.1 Status Aggregation

**Java:**
```java
public TestStatus aggregateStatuses() {
    List<TestStatus> allStatuses = getLiveInstanceUuids()
        .stream()
        .map(uuid -> readStatusFromFile(uuid))
        .collect(Collectors.toList());
    
    // Priority: FAILED > STOPPED > SKIPPED > PASSED
    if (allStatuses.contains(FAILED)) return FAILED;
    if (allStatuses.contains(STOPPED)) return STOPPED;
    if (allStatuses.contains(SKIPPED)) return SKIPPED;
    return PASSED;
}
```

**Swift:**
```swift
// We aggregate in LaunchManager Actor
actor LaunchManager {
    private var workerStatuses: [String: TestStatus] = [:]
    
    func recordStatus(_ status: TestStatus) {
        workerStatuses[workerID] = status
    }
    
    func getAggregatedStatus() -> TestStatus {
        // Same priority logic
        if workerStatuses.values.contains(.failed) { return .failed }
        if workerStatuses.values.contains(.stopped) { return .stopped }
        if workerStatuses.values.contains(.skipped) { return .skipped }
        return .passed
    }
}
```

**Advantage Java:**
- ✅ Statuses persisted to file (survives crashes)
- ✅ Primary worker has **complete view** of all statuses

**Advantage Swift:**
- ✅ Actor provides **memory-safe** access
- ✅ No file I/O overhead
- ❌ Lost if process crashes (but test run would fail anyway)

### 7.2 Multi-Process Testing

**Java Supports:**
```
Maven/Gradle Multi-Module Build:
├─ Module A tests → JVM Process 1 → Worker 1
├─ Module B tests → JVM Process 2 → Worker 2
├─ Module C tests → JVM Process 3 → Worker 3
└─ All join same launch via file lock
```

**Swift Limitation:**
```
Xcode Test Run:
├─ All test bundles → Same xcodebuild process
├─ Parallel devices → Multiple test processes (but same bundle)
└─ Already coordinated via file UUID
```

**Why This Matters Less for Swift:**
- Xcode doesn't run test bundles in separate processes like Maven modules
- Our file-based approach **already works** for parallel simulator tests
- Cross-module coordination not needed in iOS/macOS ecosystem

---

## 8. What Our Solution Does Better

### 8.1 Simplicity

**Java File Lock:**
- ~400 lines of lock management code
- Two file types (.lock + .sync)
- Timestamp management
- Heartbeat updates
- Blocking I/O with retries

**Swift File Coordination:**
- ~50 lines for UUID file handling
- One file type (uuid.txt)
- Simple age check (10 seconds)
- Non-blocking async I/O
- API handles coordination

### 8.2 Modern Concurrency

**Java (synchronized + volatile):**
```java
public class LaunchIdLockFile {
    private static volatile String lockUuid;
    private static volatile Pair<RandomAccessFile, FileLock> mainLock;
    
    public synchronized String obtainLaunchUuid(String uuid) {
        // Manual synchronization
        synchronized(this) {
            if (mainLock == null) {
                // Try acquire lock
            }
        }
    }
}
```

**Swift (Actor):**
```swift
actor LaunchManager {
    private var launchUUID: String?  // Automatically isolated
    
    func getOrCreateLaunchUUID() -> String {
        // Actor ensures serial access - no manual locks!
        if launchUUID == nil {
            launchUUID = loadFromFile()
        }
        return launchUUID!
    }
}
```

### 8.3 API-Driven Coordination

**Java:** Complex file locks to **prevent** multiple launch starts

**Swift:** Let multiple starts happen, API **handles** it via 409

```
Java Philosophy: "Prevent conflicts before they happen"
├─ File locks
├─ Socket coordination
└─ Complex state management

Swift Philosophy: "Let conflicts happen, handle gracefully"
├─ Simple UUID file
├─ All workers try API
└─ 409 = success (already created)
```

**Our Advantage:**
- Less code to maintain
- Fewer edge cases
- Relies on ReportPortal API guarantees (which we trust)

---

## 9. Edge Cases Comparison

| Scenario | Java Handling | Swift Handling |
|----------|---------------|----------------|
| **Worker crashes during test** | Heartbeat timeout (30min), then primary continues | Suite counter decrements, launch finishes when count=0 |
| **File lock held by dead process** | OS releases lock automatically | File age check (>10s = stale) |
| **Network partition** | Socket mode: connection refused, falls back to FILE | Not applicable (local only) |
| **Concurrent launch finishes** | Only primary calls API | All call API, first wins, others get 409 ✅ |
| **Status disagreement** | Primary aggregates all worker statuses | First finisher's status wins |
| **Docker container restart** | Socket mode: rebind port, FILE mode: rewrite files | Not applicable (no containers) |

---

## 10. Performance Comparison

### 10.1 Startup Overhead

**Java (FILE mode):**
```
Worker 1:
├─ Try acquire .lock file: ~5-50ms (disk I/O)
├─ Write to .sync file: ~5-10ms
└─ Total: ~10-60ms

Worker 2:
├─ Try acquire .lock file: ~5-50ms (FAIL)
├─ Read .sync file: ~5-10ms
├─ Write to .sync file: ~5-10ms
└─ Total: ~15-70ms
```

**Java (SOCKET mode):**
```
Worker 1:
├─ Bind socket: ~1-5ms (network)
├─ Start server thread: ~1-2ms
└─ Total: ~2-7ms

Worker 2:
├─ Connect socket: ~1-2ms
├─ Send/receive: ~1-2ms
└─ Total: ~2-4ms
```

**Swift (FILE + API):**
```
Worker 1:
├─ Check file: ~1ms (in-memory after first read)
├─ Write UUID: ~5ms (async, doesn't block)
├─ POST /launch: ~50-200ms (network)
└─ Total: ~56-206ms (but async!)

Worker 2:
├─ Check file: ~1ms
├─ Read UUID: ~1ms
├─ POST /launch: ~50-200ms → 409
└─ Total: ~52-202ms
```

**Analysis:**
- Java FILE: Fastest lock acquisition
- Java SOCKET: Fastest overall
- Swift: **Slower startup, but async** - doesn't block test execution

### 10.2 Runtime Overhead

**Java:**
- Heartbeat updates: Every 5 seconds → disk I/O
- Primary worker: Polling .sync file until all workers done

**Swift:**
- No heartbeat needed
- No polling needed
- Suite counter: Updates on suite start/finish only

**Winner:** Swift - less overhead during test execution

---

## 11. Recommendations

### 11.1 What We Should Keep

✅ **File-based UUID coordination** - Simple, works perfectly for iOS/macOS
✅ **Tolerant finalization** - Elegant, relies on API idempotency
✅ **Actor-based state** - Modern, safe, no manual locks
✅ **10-second staleness** - Fast enough to detect new runs, short enough to not interfere

### 11.2 What We Could Improve (Inspired by Java)

**1. Worker Registry (Optional)**

Java tracks all active workers. We could add:

```swift
actor LaunchManager {
    private var activeWorkers: Set<String> = []
    
    func registerWorker(_ id: String) {
        activeWorkers.insert(id)
        print("📊 Active workers: \(activeWorkers.count)")
    }
    
    func unregisterWorker(_ id: String) {
        activeWorkers.remove(id)
        print("📊 Remaining workers: \(activeWorkers.count)")
    }
}
```

**Benefit:** Better observability, debugging

**2. Persistent Status File (Optional)**

Java writes worker statuses to file. We could add:

```swift
func recordStatus(workerID: String, status: TestStatus) {
    let statusPath = "/tmp/reportportal/worker_\(workerID)_status.txt"
    try? status.rawValue.write(toFile: statusPath, atomically: true, encoding: .utf8)
}
```

**Benefit:** Survives crashes, better debugging

**3. Configurable Staleness Timeout**

Java uses 30 minutes, we use 10 seconds. Make it configurable:

```swift
let staleThreshold = parameters.launchUUIDStaleThreshold ?? 10.0
```

**Benefit:** Different needs for different environments

### 11.3 What We Should NOT Add

❌ **Socket coordination** - Not needed for our ecosystem
❌ **Complex lock files** - Our simple file + API works
❌ **Heartbeat mechanism** - Suite counter provides liveness
❌ **Primary/secondary distinction** - All workers are equal in our model

---

## 12. Final Verdict

### Java Agents: Enterprise-Grade, Complex

**Strengths:**
- Handles edge cases (containers, NFS, multi-module builds)
- Complete worker coordination
- Guaranteed status aggregation
- Battle-tested in production

**Weaknesses:**
- Complex codebase (~2000 lines for coordination alone)
- Blocking I/O
- Requires careful configuration
- Overkill for simpler environments

### Swift Agent: Modern, Pragmatic

**Strengths:**
- Simple, maintainable code (~500 lines total)
- Leverages modern Swift Concurrency
- API-driven coordination
- Perfect fit for iOS/macOS ecosystem

**Weaknesses:**
- No cross-container support (not needed)
- Status aggregation not guaranteed (first finisher wins)
- Less observability (no worker registry by default)

---

## 13. Conclusion

**Is our solution better?**

For the **iOS/macOS/Xcode ecosystem**: **YES!** ✅

Why:
1. **Simpler** - Java's complexity isn't needed for single-machine tests
2. **Modern** - Swift Concurrency > Java synchronized blocks
3. **Pragmatic** - API 409 handling > complex file locks
4. **Sufficient** - Solves the problem we actually have

**Should we add Java's features?**

**NO** for core functionality (socket coordination, complex locks)
**MAYBE** for observability (worker registry, status files)

**What did we learn?**

1. Java's approach is **correct** for their ecosystem (cross-container, multi-module)
2. Our approach is **correct** for our ecosystem (single-machine, Xcode-based)
3. Both solve the same problem with **different trade-offs**
4. ReportPortal API design (idempotent launches, 409 handling) enables our simpler approach

---

## Appendix: Code Snippets

### A.1 Java File Lock (Simplified)

```java
// Primary worker
FileLock lock = lockFile.getChannel().tryLock();
if (lock != null) {
    // Write UUID to both files
    writeToFile(lockFile, uuid);
    writeToFile(syncFile, timestamp + ":" + uuid);
    
    // Start launch
    launchId = client.startLaunch(uuid);
    
    // Hold lock until all workers done
    while (!allWorkersDone()) {
        Thread.sleep(1000);
    }
    
    // Finish launch
    client.finishLaunch(launchId);
    
    // Release lock
    lock.release();
}
```

### A.2 Swift File + API (Actual)

```swift
// All workers
let uuid = getOrCreateUUID() // Simple file read/write

do {
    // Try to start launch
    launchID = try await client.startLaunch(uuid)
    print("✅ Created launch")
} catch HTTPClientError.httpError(409, let body) {
    // Launch exists - extract ID from response
    launchID = extractID(from: body) ?? uuid
    print("⚡️ Joined existing launch")
}

// All workers try to finish
do {
    try await client.finishLaunch(launchID)
    print("✅ Finalized")
} catch HTTPClientError.httpError(409, _) {
    print("ℹ️ Already finalized - OK!")
}
```

**Lines of Code:**
- Java coordination: ~2000 lines
- Swift coordination: ~200 lines

**Complexity:**
- Java: High (locks, sockets, threads, heartbeats)
- Swift: Low (file, actor, API)

**Result:**
- Both work correctly for their ecosystems ✅
