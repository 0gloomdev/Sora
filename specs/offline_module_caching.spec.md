# Spec: Offline Module Caching

**Status:** [Ready for Dev]

## 1. Problem Statement
Sora currently downloads JS modules from remote URLs on every app launch or when adding a module. This requires network connectivity and prevents offline browsing. Modules should be cached persistently with validation against remote versions.

## 2. Solution Design

### 2.1 Storage Layer
- **SQLite database** (via `SQLite.swift` or GRDB) for metadata + cache versioning
- **File system** for JS script content (one file per module: `{moduleId}.js`)
- **Cache directory**: `Documents/ModuleCache/`

### 2.2 Cache Metadata Schema (SQLite table `module_cache`)
```sql
CREATE TABLE module_cache (
    id TEXT PRIMARY KEY,              -- UUID
    source_name TEXT NOT NULL,
    version TEXT NOT NULL,            -- remote version string
    script_hash TEXT NOT NULL,        -- SHA256 of script content
    script_path TEXT NOT NULL,        -- relative path in ModuleCache/
    metadata_json TEXT NOT NULL,      -- full ModuleMetadata JSON
    last_fetched INTEGER NOT NULL,    -- Unix timestamp
    etag TEXT,                        -- HTTP ETag for conditional requests
    last_modified TEXT,               -- HTTP Last-Modified header
    is_valid BOOLEAN DEFAULT 1,       -- soft delete flag
    created_at INTEGER DEFAULT (strftime('%s','now'))
);
CREATE INDEX idx_module_cache_valid ON module_cache(is_valid);
```

### 2.3 Cache Manager API (`ModuleCacheManager.swift`)
```swift
protocol ModuleCacheManager {
    // Fetch: check cache first, then conditional HTTP request if stale
    func getModule(_ moduleId: UUID) async throws -> SoraModuleInstance?
    
    // Store: download script, compute hash, save to FS + DB
    func cacheModule(_ metadata: ModuleMetadata, scriptContent: String) async throws
    
    // Validation: conditional GET with ETag/Last-Modified
    func validateRemoteVersion(_ metadata: ModuleMetadata) async throws -> CacheValidationResult
    
    // Cleanup: remove soft-deleted entries, enforce size limit
    func cleanup(maxSizeMB: Int = 100) async
    
    // Migration: handle schema changes
    func migrateIfNeeded() async throws
}
```

### 2.4 Validation Strategies
| Strategy | Headers | Trigger |
|----------|---------|---------|
| **ETag** | `If-None-Match` | Server supports ETag |
| **Last-Modified** | `If-Modified-Since` | Fallback |
| **Full Re-fetch** | None | No validators available |

### 2.5 Integration Points
- `ModuleManager.addModule()` → `ModuleCacheManager.cacheModule()`
- `ModuleManager.refreshModules()` → `ModuleCacheManager.validateRemoteVersion()`
- `JSController.loadModule()` → `ModuleCacheManager.getModule()` (offline-first)

## 3. Acceptance Criteria
1. **Offline browsing**: Modules load from cache when offline (no network required).
2. **Version freshness**: Remote version checked via conditional GET; cache updated only on change.
3. **Cache size limit**: Configurable max size (default 100MB), LRU eviction of least recently used.
3. **Schema migration**: Automatic migration on app upgrade.
4. **Tests**: Unit tests for cache hit/miss, ETag/Last-Modified validation, LRU eviction.

## 4. Test Cases
- `testCacheHitReturnsModuleWithoutNetwork`: Module loads from cache without HTTP request.
- `testCacheMissFetchesAndCaches`: First load stores to FS + DB.
- `testETagValidationReturnsNotModified`: HTTP 304 returns cached module.
- `testLastModifiedValidationReturnsNotModified`: HTTP 304 with Last-Modified.
- `testLRUEvictionRespectsSizeLimit`: 101st module evicts LRU entry.
- `testCorruptedCacheFileRecovers`: Corrupt file triggers re-download.

---

*Spec approved for implementation. Coder may proceed.*