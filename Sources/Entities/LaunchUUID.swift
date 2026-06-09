//  Created by Ruslan Popesku on 10/22/25.
//  Copyright 2025 EPAM Systems
//  
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//  
//      https://www.apache.org/licenses/LICENSE-2.0
//  
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation

/// The launch UUID for this process — resolved once, stable across all calls.
///
/// On SauceLabs each shard = separate process = separate launch. No cross-process
/// coordination is needed. The UUID is either:
/// 1. From `RP_LAUNCH_UUID` env var (CI/CD parallel workers sharing one launch on same machine)
/// 2. Auto-generated once per process (SauceLabs/local mode: each process = own launch)
///
/// This is a caseless `enum` (cannot be instantiated) with a single `static let`.
/// Thread-safe by Swift semantics — `static let` is lazily initialized once with a
/// dispatch_once-like guarantee, no locks needed.
enum LaunchUUID {
    
    /// The launch UUID for this process.
    static let value: String = {
        if let ciUUID = ProcessInfo.processInfo.environment["RP_LAUNCH_UUID"],
           !ciUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Logger.shared.info("📦 [CI Mode] Using shared launch UUID: \(ciUUID)")
            return ciUUID
        }
        let uuid = UUID().uuidString
        Logger.shared.info("📦 [Per-Process Mode] Generated launch UUID: \(uuid) (this process gets its own launch)")
        return uuid
    }()
}
