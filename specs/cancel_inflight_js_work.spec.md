# Spec: Cancel In-Flight JS Work on Module Switch

**Status:** [COMPLETED - PASSED]

## 1. Problem Statement
When a user switches modules (or the active module changes), any in-flight JavaScript async operations (search, details, stream, chapters, extractText) continue running and may resolve on a stale `JSContext`, causing:
- Memory leaks from abandoned `CheckedContinuation` objects
- Wrong data delivered to UI (stale module's data)
- WKWebView loads (`soraWebFetch`) continuing after module invalidation

## 2. Solution Design
Introduce a **generation counter** (`moduleGeneration: UInt64`) on `JSController`:
- Incremented on every `loadModule()` and `invalidateModule()/invalidateAllModules()`
- Each public async entry point captures the generation at call time
- Async work checks generation before resolving; if stale, aborts with `CancellationError`

## 3. Interface Contracts

### 3.1 New Fields on `JSController`
```swift
private var moduleGeneration: UInt64 = 0
```

### 3.2 Helper Methods
```swift
/// Checks if the current module generation matches; throws CancellationError if stale.
private func checkGeneration(_ gen: UInt64) throws {
    guard gen == moduleGeneration else { throw CancellationError() }
}

/// Wraps an async operation with generation checking for cancellation.
@discardableResult
private func withGeneration<T>(_ gen: UInt64, _ operation: @Sendable () async throws -> T) async throws -> T
```

### 3.3 Modified Public APIs (capture generation at call site)
```swift
func fetchStreamUrl(episodeUrl: String, softsub: Bool = false, module: ScrapingModule, completion: @escaping ((streams: [String]?, subtitles: [String]?, sources: [[String:Any]]? )) -> Void)
func fetchDetails(url: String, completion: @escaping ([MediaItem], [EpisodeLink]) -> Void)
func fetchSearchResults(keyword: String, module: ScrapingModule, completion: @escaping ([SearchItem]) -> Void)
func extractChapters(moduleId: UUID, href: String, completion: @escaping ([[String: Any]]) -> Void)
func extractText(moduleId: UUID, href: String, completion: @escaping (Result<String, Error>) -> Void)
```

### 3.4 Invalidation Increments Generation
```swift
func invalidateModule(id: UUID) { moduleGeneration &+= 1; ... }
func invalidateAllModules() { moduleGeneration &+= 1; ... }
```

## 4. Acceptance Criteria
1. **No memory leaks**: After switching modules, no dangling `CheckedContinuation` remains.
2. **No stale data**: If module A's request completes after module B is loaded, module A's result is discarded.
3. **Graceful cancellation**: `CancellationError` is caught and silently ignored (no UI error).
4. **All existing tests pass**: 44/44 SoraTests green.
5. **Build succeeds**: `xcodebuild` clean build + test suite green.

## 5. Test Cases (to add to SoraTests/SoraEngineTests.swift)
- `testModuleSwitchCancelsPendingSearch`: Start search on module A, switch to module B before completion → no completion called, no crash.
- `testModuleSwitchCancelsPendingStream`: Start stream fetch on module A, switch before completion → no completion called.
- `testRapidModuleSwitchNoLeak`: Rapidly switch modules 10x → no memory growth, no crashes.

---

*Spec approved for implementation. Coder may proceed.*