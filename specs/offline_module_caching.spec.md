# Spec: Offline Module Caching

**Status:** [Ready for Dev]

## 1. PROBLEM STATEMENT

Sora is a modular media player that loads JavaScript scraping modules from remote URLs. Currently, every app launch or module switch triggers a fresh HTTP request to fetch the JS module, even when:

1. The user is offline (no network connectivity)
2. The module hasn't changed on the server (wasted bandwidth)
3. The app was recently used and the module should be instantly available

**Required behavior:**
- **Offline-First**: App must load and execute modules from local SQLite cache when offline
- **Zero-RTT on cache hit**: Previously loaded modules execute instantly on subsequent app launches
- **Conditional validation**: When online, use ETag/Last-Modified for 304 Not Modified responses to avoid re-downloading unchanged scripts
- **Graceful degradation**: If network fails, fall back to cached version without user-visible interruption

## 2. STORAGE LAYER (SQLite Schema)

### Table: `module_cache`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | TEXT | PRIMARY KEY | Module UUID (matches `ScrapingModule.id`) |
| `script_content` | TEXT | NOT NULL | Complete JavaScript source code |
| `version` | TEXT | NOT NULL | Module version string (e.g., "1.2.3") |
| `etag` | TEXT | NULLABLE | HTTP ETag from server for conditional GET |
| `last_updated` | INTEGER | NOT NULL | Unix timestamp (seconds since epoch) |
| `script_hash` | TEXT | NOT NULL | SHA-256 hex of script content for integrity |
| `metadata_json` | TEXT | NOT NULL | Full `ModuleMetadata` JSON for cache reconstruction |

### Indexes
```sql
CREATE INDEX idx_module_cache_valid ON module_cache(is_valid);
CREATE INDEX idx_module_cache_last_fetched ON module_cache(last_fetched);
```

### Filesystem Layout
```
Application Support/
└── ModuleCache/
    ├── module_cache.sqlite          (GRDB database)
    └── scripts/
        ├── <module-id>.js           # One file per module
        └── ...
```

## 3. MODULECACHEMANAGER API (Swift Contract)

```swift
@MainActor
public final class ModuleCacheManager {
    public static let shared = ModuleCacheManager()
    
    /// Retrieve cached module script by ID.
    /// Returns nil if not cached or marked invalid.
    public func getCachedModule(id: UUID) async throws -> (script: String, metadata: ModuleMetadata)?
    
    /// Persist module script and metadata to cache.
    /// Computes SHA-256 hash for integrity validation.
    /// Updates ETag/Last-Modified if provided via CacheValidationResult.
    public func saveModuleToCache(
        id: UUID,
        metadata: ModuleMetadata,
        script: String
    ) async throws
    
    /// Validate cached module against remote using ETag/Last-Modified.
    /// Returns CacheValidationResult indicating freshness and optional new content.
    public func validateRemoteVersion(_ metadata: ModuleMetadata) async throws -> CacheValidationResult
    
    /// Invalidate (soft delete) a module from cache.
    public func invalidateModule(id: UUID) async throws
    
    /// Clear all cached modules (hard delete).
    public func clearCache() async throws
    
    /// Get cache statistics (count, total size in bytes).
    public func getCacheStats() async throws -> (count: Int, totalSizeBytes: Int64)
}

/// Result of remote validation against cached module.
public struct CacheValidationResult {
    public let isUpToDate: Bool          // true if 304 Not Modified
    public let newVersion: String?       // New version string if changed
    public let etag: String?             // New ETag from server
    public let lastModified: String?     // New Last-Modified header
    public let scriptContent: String?    // New script content (if changed)
    
    public init(isUpToDate: Bool, newVersion: String? = nil, etag: String? = nil, lastModified: String? = nil, scriptContent: String? = nil)
}

/// Errors specific to cache operations.
public enum CacheError: Error, LocalizedError {
    case moduleNotFound
    case invalidMetadata
    case networkError(Error)
    case hashMismatch
    case ioError(Error)
    case databaseError(Error)
    
    public var errorDescription: String? { ... }
}
```

### Concurrency & Thread Safety
- All public methods are `@MainActor` isolated
- Internally uses GRDB `DatabaseQueue` for thread-safe SQLite access
- `pendingRequests` dictionary deduplicates concurrent identical requests

## 4. VALIDATION & FALLBACK STRATEGIES

### Offline-First Strategy (Priority 1)
```
User requests module
    ↓
Check SQLite cache (instant)
    ↓
    ├─ Found & valid → Execute immediately (0ms network)
    └─ Not found → Attempt network fetch → cache → execute
```

### Online Validation Strategy (Priority 2)
```
Cache hit → Check last_fetched > TTL?
    ├─ Fresh (< 24h) → Skip network, execute cached
    └─ Stale → HEAD request with ETag/Last-Modified
        ├─ 304 Not Modified → Update last_fetched, use cached
        ├─ 200 OK → Download new script, update cache, execute
        └─ Error (timeout/5xx) → Log warning, serve stale cached
```

### Offline Fallback
- Network timeout/unreachable → Serve stale cached script
- Corrupted cache entry → Delete entry, fallback to network
- Invalid JSON/script → Delete entry, trigger re-download

### Deduplication
```swift
// Concurrent identical requests coalesced
let key = "search|keyword|moduleId"
let task = pendingRequests[key] ?? Task { ... }
pendingRequests[key] = task
```

## 5. ACCEPTANCE CRITERIA & TEST CASES

### Test Case 1: `testOfflineLoadingFallback`
**Given**: Module previously cached, device in airplane mode  
**When**: User opens module detail screen  
**Then**: Module executes from SQLite cache within 100ms, no network request attempted

```swift
func testOfflineLoadingFallback() async throws {
    let cache = ModuleCacheManager.shared!
    let module = try makeCachedModule()
    
    // Simulate offline by disabling network
    await withOfflineMode {
        let (script, metadata) = try await cacheManager.getCachedModule(id: module.id)
        XCTAssertNotNil(script)
        XCTAssertEqual(metadata.sourceName, "TestModule")
    }
}
```

### Test Case 2: `testEtag304Hit`
**Given**: Module cached with ETag `"abc123"`, server returns 304  
**When**: `validateRemoteVersion()` called  
**Then**: Returns `isUpToDate == true`, no script downloaded, `last_fetched` updated

```swift
func testEtag304Hit() async throws {
    let cache = ModuleCacheManager.shared!
    let metadata = makeMetadata(etag: "abc123")
    
    // Mock HTTP 304 response
    let mockServer = MockHTTPServer()
    mockServer.enqueue(HTTPURLResponse(
        url: metadata.scriptUrl,
        statusCode: 304,
        httpVersion: nil,
        headerFields: ["ETag": "abc123"]
    )!)
    
    let result = try await cache.validateRemoteVersion(metadata)
    XCTAssertTrue(result.isUpToDate)
    XCTAssertNil(result.scriptContent)
}
```

### Test Case 3: `testCacheEvictionLRU`
**Given**: Cache at 95MB limit, new 10MB module added  
**When**: `saveModuleToCache` triggers LRU eviction  
**Then**: Oldest unused module evicted, total size ≤ 100MB

```swift
func testCacheEvictionLRU() async throws {
    let cache = ModuleCacheManager.shared!
    try await cache.clearCache()
    
    // Fill cache to ~95MB
    for i in 0..<16 {
        let script = String(repeating: "x", count: 6_500_000) // ~6MB
        let module = makeModule(version: "\(i).0")
        try await cache.saveModuleToCache(id: module.id, metadata: module.metadata, script: script)
    }
    
    // Add one more module → should evict LRU
    let newModule = try makeModule(version: "99.0")
    try await cache.saveModuleToCache(id: newModule.id, metadata: newModule.metadata, script: String(repeating: "y", count: 6_500_000))
    
    let (count, totalSize) = try await cacheManager.getCacheStats()
    XCTAssertLessThanOrEqual(totalSize, 100 * 1024 * 1024 + 1_000_000) // ≤ 101MB
}
```

### Additional Tests (Recommended)
- `testETagMismatchTriggersDownload`: ETag changed → 200 OK → script updated
- `testLastModifiedValidation`: Last-Modified header triggers revalidation
- `testCorruptedCacheFileRecovered`: Corrupt `.js` file deleted, re-fetched
- `testCacheSizeLimitEnforcement`: Exactly at 100MB boundary
- `testConcurrentDeduplication`: Parallel identical requests share single download

---

**Dependencies**: GRDB.swift ≥ 6.28, CryptoKit (SHA256), FoundationNetworking (URLSession.custom)

**Files to Create/Modify**:
- `Sora/Utlis & Misc/ModuleCache/ModuleCacheManager.swift` (new)
- `Sora/Utlis & Misc/ModuleCache/ModuleCacheManagerTests.swift` (new)
- `Sora/Utlis & Misc/Modules/ModuleSpec.swift` (add `id: UUID` to `ModuleMetadata`)
- `Sulfur.xcodeproj` (add GRDB package, ModuleCacheManager to Sulfur target)
- `SoraTests/SoraEngineTests.swift` (add `ModuleCacheManagerTests`)

---

*Spec approved for implementation. Coder may proceed.*