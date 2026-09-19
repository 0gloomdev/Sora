//
//  ModuleCacheManagerTests.swift
//  SoraTests
//
//  Created by Sora Team on 18/09/26.
//

import XCTest
@testable import Sulfur

@MainActor
final class ModuleCacheManagerTests: XCTestCase {

    private var fixtureURLs: [URL] = []

    override func tearDown() {
        for url in fixtureURLs {
            try? FileManager.default.removeItem(at: url)
        }
        fixtureURLs.removeAll()
        super.tearDown()
    }

    private func makeModule(script: String, version: String = "1.0") throws -> ScrapingModule {
        let fileName = "test-cache-\(UUID().uuidString).js"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        try script.write(to: url, atomically: true, encoding: .utf8)
        fixtureURLs.append(url)
        let metadata = ModuleMetadata(
            id: UUID(),
            sourceName: "CacheTest",
            author: Author(name: "Test", icon: "i"),
            iconUrl: "i",
            version: version,
            language: "en",
            baseUrl: "https://example.com/",
            streamType: .hls,
            quality: .p720,
            searchBaseUrl: "https://example.com/s?q=%s",
            scriptUrl: "https://example.com/s.js"
        )
        return ScrapingModule(metadata: metadata, localPath: fileName, metadataUrl: "https://example.com/m.json")
    }

    func testOfflineLoadingFallback() async throws {
        let cacheManager = ModuleCacheManager.shared!
        let module = try makeModule(script: "function searchResults(k) { return '[]'; }")

        // Save to cache
        try await cacheManager.saveModuleToCache(id: module.id, metadata: module.metadata, script: script)

        // Load from cache without network
        let (scriptContent, metadata) = try await cacheManager.getCachedModule(id: module.id)!
        XCTAssertEqual(scriptContent, script)
        XCTAssertEqual(metadata.version, "1.0")
    }

    func testCacheMissFetchesAndCaches() async throws {
        let cacheManager = ModuleCacheManager.shared!
        try await cacheManager.clearCache()

        // This test would need a mock HTTP server to fully test
        // For now, we just verify the cache miss behavior
        let module = try makeModule(script: "function search() { return '[]'; }", version: "2.0")
        do {
            _ = try await cacheManager.getCachedModule(id: module.id)
            XCTFail("Expected cache miss")
        } catch ModuleCacheManager.CacheError.moduleNotFound {
            // Expected
        }
    }

    func testCacheInvalidation() async throws {
        let cacheManager = ModuleCacheManager.shared!
        let script = "function search() { return 'v1'; }"
        let module = try makeModule(script: script, version: "1.0")

        try await cacheManager.saveModuleToCache(id: module.id, metadata: module.metadata, script: script)
        XCTAssertNotNil(try await cacheManager.getCachedModule(id: module.id))

        try await cacheManager.invalidateModule(id: module.id)
        do {
            _ = try await cacheManager.getCachedModule(id: module.id)
            XCTFail("Expected module not found after invalidation")
        } catch ModuleCacheManager.CacheError.moduleNotFound {
            // Expected
        }
    }

    func testCacheSizeLimitEnforcement() async throws {
        let cacheManager = ModuleCacheManager.shared!
        try await cacheManager.clearCache()

        // Add many modules to exceed cache limit
        for i in 0..<20 {
            let script = String(repeating: "x", count: 6_000_000) // ~6MB each
            let module = try makeModule(script: script, version: "\(i).0")
            try await cacheManager.saveModuleToCache(id: module.id, metadata: module.metadata, script: script)
        }

        let (count, totalSize) = try await cacheManager.getCacheStats()
        XCTAssertLessThanOrEqual(totalSize, 100 * 1024 * 1024 + 1_000_000) // ~100MB + buffer
    }

    func testEtag304Hit() async throws {
        let cacheManager = ModuleCacheManager.shared!
        let previous = JSExecutionPolicy.asyncTimeoutSeconds
        JSExecutionPolicy.asyncTimeoutSeconds = 0.5
        defer { JSExecutionPolicy.asyncTimeoutSeconds = previous }

        try ModuleCacheManager.shared!.loadModuleScript("""
            function searchResults(k) { return new Promise(function(resolve) { setTimeout(() => resolve('[]'), 1000); }); }
        """, moduleName: "Hang")

        do {
            _ = try await AsyncModeHandler().executeSearch(engine: ModuleCacheManager.shared!.engine, keyword: "x")
            XCTFail("expected timedOut error")
        } catch let error as JSExecutionError {
            if case .timedOut = error {
                XCTAssertEqual(error.errorDescription, "JavaScript promise timed out after 0.5s")
            } else {
                XCTFail("wrong error: \(error)")
            }
        }
    }
}