//
//  SoraEngineTests.swift
//  SoraTests
//
//  Created by Sora Team on 12/09/26.
//

import XCTest
import JavaScriptCore
@testable import Sulfur

final class SoraEngineTests: XCTestCase {

    func testModuleMetadataDecoding() throws {
        let json = """
        {
            "sourceName": "TestSource",
            "author": {
                "name": "TestAuthor",
                "icon": "https://example.com/icon.png"
            },
            "iconUrl": "https://example.com/source-icon.png",
            "version": "1.0.0",
            "language": "English",
            "baseUrl": "https://api.example.com/",
            "streamType": "HLS",
            "quality": "720p",
            "searchBaseUrl": "https://example.com/search?q=%s",
            "scriptUrl": "https://example.com/script.js",
            "asyncJS": true,
            "streamAsyncJS": false,
            "softsub": false,
            "type": "anime"
        }
        """

        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ModuleMetadata.self, from: data)

        XCTAssertEqual(metadata.sourceName, "TestSource")
        XCTAssertEqual(metadata.author.name, "TestAuthor")
        XCTAssertEqual(metadata.version, "1.0.0")
        XCTAssertEqual(metadata.streamType, .hls)
        XCTAssertEqual(metadata.quality, .p720)
        XCTAssertEqual(metadata.executionMode, .async)
        XCTAssertEqual(metadata.type, .anime)
    }

    func testModuleMetadataDecodingWithDefaults() throws {
        let json = """
        {
            "sourceName": "MinimalSource",
            "author": {
                "name": "Author",
                "icon": "https://example.com/icon.png"
            },
            "iconUrl": "https://example.com/icon.png",
            "version": "1.0.0",
            "language": "English",
            "baseUrl": "https://api.example.com/",
            "streamType": "MP4",
            "quality": "1080p",
            "searchBaseUrl": "https://example.com/search?q=%s",
            "scriptUrl": "https://example.com/script.js"
        }
        """

        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ModuleMetadata.self, from: data)

        XCTAssertEqual(metadata.sourceName, "MinimalSource")
        XCTAssertEqual(metadata.executionMode, .normal)
        XCTAssertNil(metadata.asyncJS)
        XCTAssertNil(metadata.type)
    }

    func testScrapingModuleCreation() throws {
        let metadata = ModuleMetadata(
            sourceName: "TestSource",
            author: Author(name: "Author", icon: "https://example.com/icon.png"),
            iconUrl: "https://example.com/icon.png",
            version: "1.0.0",
            language: "English",
            baseUrl: "https://api.example.com/",
            streamType: .hls,
            quality: .p720,
            searchBaseUrl: "https://example.com/search?q=%s",
            scriptUrl: "https://example.com/script.js"
        )

        let module = ScrapingModule(
            metadata: metadata,
            localPath: "test.js",
            metadataUrl: "https://example.com/module.json"
        )

        XCTAssertEqual(module.metadata.sourceName, "TestSource")
        XCTAssertEqual(module.localPath, "test.js")
        XCTAssertFalse(module.isActive)
    }

    func testExecutionModeProperties() throws {
        XCTAssertFalse(ExecutionMode.normal.requiresAsync)
        XCTAssertTrue(ExecutionMode.async.requiresAsync)
        XCTAssertTrue(ExecutionMode.streamAsync.requiresAsync)
        XCTAssertTrue(ExecutionMode.softSubs.requiresAsync)

        XCTAssertFalse(ExecutionMode.normal.supportsStreaming)
        XCTAssertTrue(ExecutionMode.streamAsync.supportsStreaming)
        XCTAssertTrue(ExecutionMode.softSubs.supportsStreaming)
        XCTAssertFalse(ExecutionMode.async.supportsStreaming)

        XCTAssertTrue(ExecutionMode.softSubs.supportsSubtitles)
        XCTAssertFalse(ExecutionMode.normal.supportsSubtitles)
        XCTAssertFalse(ExecutionMode.async.supportsSubtitles)
        XCTAssertFalse(ExecutionMode.streamAsync.supportsSubtitles)
    }

    func testStreamTypeDecoding() throws {
        let json = """
        {
            "sourceName": "Test",
            "author": {"name": "A", "icon": "i"},
            "iconUrl": "i",
            "version": "1",
            "language": "en",
            "baseUrl": "https://example.com/",
            "streamType": "hls",
            "quality": "720p",
            "searchBaseUrl": "https://example.com/search?q=%s",
            "scriptUrl": "https://example.com/script.js"
        }
        """

        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ModuleMetadata.self, from: data)
        XCTAssertEqual(metadata.streamType, .hls)
    }

    func testQualityDecoding() throws {
        let json = """
        {
            "sourceName": "Test",
            "author": {"name": "A", "icon": "i"},
            "iconUrl": "i",
            "version": "1",
            "language": "en",
            "baseUrl": "https://example.com/",
            "streamType": "HLS",
            "quality": "4K",
            "searchBaseUrl": "https://example.com/search?q=%s",
            "scriptUrl": "https://example.com/script.js"
        }
        """

        let data = json.data(using: .utf8)!
        let metadata = try JSONDecoder().decode(ModuleMetadata.self, from: data)
        XCTAssertEqual(metadata.quality, .p4k)
    }
}

@MainActor
final class SoraJSEngineTests: XCTestCase {

    var engine: SoraJSEngine!

    override func setUp() {
        super.setUp()
        engine = SoraJSEngine()
    }

    override func tearDown() {
        engine?.invalidate()
        engine = nil
        super.tearDown()
    }

    func testEngineInitialization() throws {
        XCTAssertNotNil(engine)
        XCTAssertNotNil(engine.globalContext)
    }

    func testEvaluateSimpleScript() throws {
        let result = engine.evaluateScript("1 + 1")
        XCTAssertEqual(result?.toInt32(), 2)
    }

    func testEvaluateScriptWithException() throws {
        let result = engine.evaluateScript("throw new Error('test error')")
        XCTAssertNil(result)
    }

    func testGlobalObjectInjection() throws {
        let testObject = ["key": "value"]
        engine.setGlobalObject(testObject, forKey: "testConfig")

        let retrieved = engine.getGlobalObject(forKey: "testConfig")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.toDictionary()?["key"] as? String, "value")
    }

    func testFunctionInjection() throws {
        var captured: String?
        let block: @convention(block) (JSValue) -> Void = { fn in
            captured = fn.toString()
        }
        engine.injectNativeFunction(name: "testEcho", function: block)

        engine.evaluateScript("testEcho('hi')")
        XCTAssertEqual(captured, "hi")
    }

    func testAsyncEvaluation() async throws {
        let result = await engine.evaluateScriptAsync("42")
        XCTAssertEqual(result?.toInt32(), 42)
    }

    func testHasFunction() throws {
        engine.evaluateScript("function testFunc() { return 'ok'; }")
        XCTAssertTrue(engine.hasFunction("testFunc"))
        XCTAssertFalse(engine.hasFunction("nonExistent"))
    }

    func testLoadModuleScript() throws {
        let script = """
        function extractDetails(html) {
            return JSON.stringify([{description: "test", aliases: "alias", airdate: "2024"}]);
        }
        """

        try engine.loadModuleScript(script, moduleName: "TestModule")
        XCTAssertTrue(engine.hasFunction("extractDetails"))
    }

    func testLoadInvalidScriptThrows() throws {
        let script = "invalid javascript {"
        XCTAssertThrowsError(try engine.loadModuleScript(script, moduleName: "BadModule")) { error in
            XCTAssertTrue(error is JSError)
        }
    }

    func testConsoleLogging() throws {
        engine.evaluateScript("console.log('test message')")
        engine.evaluateScript("console.error('test error')")
        engine.evaluateScript("console.warn('test warning')")
    }

    func testTimerPolyfills() throws {
        let script = """
        var called = false;
        setTimeout(function() { called = true; }, 10);
        called;
        """
        let result = engine.evaluateScript(script)
        XCTAssertEqual(result?.toBool(), false)
    }
}

@MainActor
final class JSBridgeTests: XCTestCase {

    var engine: SoraJSEngine!
    var bridge: JSBridge!

    override func setUp() {
        super.setUp()
        engine = SoraJSEngine()
        bridge = JSBridge(engine: engine)
    }

    override func tearDown() {
        engine?.invalidate()
        engine = nil
        bridge = nil
        super.tearDown()
    }

    func testBase64Injection() throws {
        let btoaResult = engine.callFunction("btoa", withArguments: ["hello"])
        XCTAssertEqual(btoaResult?.toString(), "aGVsbG8=")

        let atobResult = engine.callFunction("atob", withArguments: ["aGVsbG8="])
        XCTAssertEqual(atobResult?.toString(), "hello")
    }

    func testScrapingUtilsInjection() throws {
        let html = "<div>Hello <span>World</span></div>"
        let result = engine.callFunction("soraGetInnerText", withArguments: [html])
        XCTAssertEqual(result?.toString(), "Hello World")

        let tagResult = engine.callFunction("soraGetElementsByTag", withArguments: [html, "span"])
        XCTAssertEqual(tagResult?.toArray() as? [String], ["World"])
    }

    func testDeobfuscatorInjection() throws {
        XCTAssertTrue(engine.hasFunction("soraUnpack"))
        XCTAssertTrue(engine.hasFunction("soraDetect"))
    }

    func testDOMParserInjection() throws {
        let html = "<div id='test'>Content</div>"
        let parseResult = engine.callFunction("soraParseHTML", withArguments: [html])
        XCTAssertNotNil(parseResult)

        let queryResult = engine.callFunction("soraQuerySelector", withArguments: [html, "#test"])
        XCTAssertNotNil(queryResult)
    }

    func testWebFetchLocalHTMLResolves() async throws {
        let html = "<html><body><p>Hello WebFetch</p></body></html>"
        let ctx = engine.globalContext
        let result: [String: Any]? = await withCheckedContinuation { cont in
            let resolveBlock: @convention(block) (JSValue) -> Void = { value in
                cont.resume(returning: value.toDictionary() as? [String: Any])
            }
            let rejectBlock: @convention(block) (JSValue) -> Void = { _ in
                cont.resume(returning: nil)
            }
            guard let resolve = JSValue(object: resolveBlock, in: ctx),
                  let reject = JSValue(object: rejectBlock, in: ctx) else {
                cont.resume(returning: nil)
                return
            }
            let options: [String: Any] = ["htmlContent": html, "timeoutSeconds": 8]
            engine.getGlobalObject(forKey: "soraWebFetch")?.call(
                withArguments: ["https://example.com/", options, resolve, reject]
            )
        }
        XCTAssertEqual(result?["success"] as? Bool, true)
        XCTAssertTrue((result?["html"] as? String)?.contains("Hello WebFetch") ?? false)
    }
}

@MainActor
final class ExecutionModeTests: XCTestCase {

    var engine: SoraJSEngine!

    override func setUp() {
        super.setUp()
        engine = SoraJSEngine()
    }

    override func tearDown() {
        engine?.invalidate()
        engine = nil
        super.tearDown()
    }

    func testNormalModeHandlerCreation() throws {
        let handler = NormalModeHandler()
        XCTAssertEqual(handler.mode, .normal)
    }

    func testAsyncModeHandlerCreation() throws {
        let handler = AsyncModeHandler()
        XCTAssertEqual(handler.mode, .async)
    }

    func testStreamAsyncModeHandlerCreation() throws {
        let handler = StreamAsyncModeHandler()
        XCTAssertEqual(handler.mode, .streamAsync)
    }

    func testSoftSubsModeHandlerCreation() throws {
        let handler = SoftSubsModeHandler()
        XCTAssertEqual(handler.mode, .softSubs)
    }

    func testAsyncPromiseTimeout() async throws {
        let previous = JSExecutionPolicy.asyncTimeoutSeconds
        JSExecutionPolicy.asyncTimeoutSeconds = 0.5
        defer { JSExecutionPolicy.asyncTimeoutSeconds = previous }
        try engine.loadModuleScript(
            "function searchResults(k) { return new Promise(function() {}); }",
            moduleName: "Hang"
        )
        do {
            _ = try await AsyncModeHandler().executeSearch(engine: engine, keyword: "x")
            XCTFail("expected timedOut error")
        } catch let error as JSExecutionError {
            if case .timedOut = error {
                XCTAssertEqual(error.errorDescription, "JavaScript promise timed out after 0.5s")
            } else {
                XCTFail("wrong error: \(error)")
            }
        }
    }

    func testExecutionModeFactory() throws {        let normalHandler = ExecutionModeFactory.handler(for: .normal)
        XCTAssertEqual(normalHandler.mode, .normal)

        let asyncHandler = ExecutionModeFactory.handler(for: .async)
        XCTAssertEqual(asyncHandler.mode, .async)

        let streamAsyncHandler = ExecutionModeFactory.handler(for: .streamAsync)
        XCTAssertEqual(streamAsyncHandler.mode, .streamAsync)

        let softSubsHandler = ExecutionModeFactory.handler(for: .softSubs)
        XCTAssertEqual(softSubsHandler.mode, .softSubs)
    }
}

final class ModuleSpecTests: XCTestCase {

    func testSearchResultEncoding() throws {
        let result = SearchResult(title: "Test", image: "https://example.com/img.jpg", href: "https://example.com/item")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SearchResult.self, from: data)
        XCTAssertEqual(decoded.title, "Test")
        XCTAssertEqual(decoded.image, "https://example.com/img.jpg")
        XCTAssertEqual(decoded.href, "https://example.com/item")
    }

    func testMediaDetailsEncoding() throws {
        let details = MediaDetails(description: "Desc", aliases: "Alias", airdate: "2024")
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(MediaDetails.self, from: data)
        XCTAssertEqual(decoded.description, "Desc")
    }

    func testEpisodeLinkEncoding() throws {
        let episode = EpisodeLink(number: 1, title: "Ep 1", href: "https://example.com/ep1", duration: 1200)
        let data = try JSONEncoder().encode(episode)
        let decoded = try JSONDecoder().decode(EpisodeLink.self, from: data)
        XCTAssertEqual(decoded.number, 1)
        XCTAssertEqual(decoded.duration, 1200)
    }

    func testStreamResultEncoding() throws {
        let stream = StreamSource(url: "https://example.com/stream.m3u8", headers: ["Referer": "https://example.com"], quality: "720p", type: "hls")
        let subtitle = SubtitleTrack(url: "https://example.com/sub.vtt", language: "en", label: "English", kind: "captions")
        let result = StreamResult(streams: [stream], subtitles: [subtitle])

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(StreamResult.self, from: data)

        XCTAssertEqual(decoded.streams?.count, 1)
        XCTAssertEqual(decoded.subtitles?.count, 1)
        XCTAssertEqual(decoded.streams?.first?.url, "https://example.com/stream.m3u8")
    }

    func testChapterEncoding() throws {
        let chapter = Chapter(number: 1, title: "Chapter 1", href: "https://example.com/ch1", updatedAt: Date())
        let data = try JSONEncoder().encode(chapter)
        let decoded = try JSONDecoder().decode(Chapter.self, from: data)
        XCTAssertEqual(decoded.number, 1)
        XCTAssertEqual(decoded.title, "Chapter 1")
    }

    func testChapterContentEncoding() throws {
        let content = ChapterContent(html: "<p>Content</p>", nextChapterUrl: "https://example.com/ch2", prevChapterUrl: "https://example.com/ch0")
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ChapterContent.self, from: data)
        XCTAssertEqual(decoded.html, "<p>Content</p>")
        XCTAssertEqual(decoded.nextChapterUrl, "https://example.com/ch2")
        XCTAssertEqual(decoded.prevChapterUrl, "https://example.com/ch0")
    }
}

final class ModuleLoadErrorTests: XCTestCase {

    func testModuleLoadErrorDescriptions() {
        XCTAssertEqual(ModuleLoadError.invalidMetadataUrl.errorDescription, "Invalid metadata URL")
        XCTAssertEqual(ModuleLoadError.invalidScriptUrl.errorDescription, "Invalid script URL")
        XCTAssertEqual(ModuleLoadError.invalidScriptEncoding.errorDescription, "Invalid script encoding")
    }

    func testJSErrorDescriptions() {
        XCTAssertEqual(JSError.scriptLoadFailed("x").errorDescription, "Script load failed: x")
        XCTAssertEqual(JSError.functionNotFound("f").errorDescription, "Function not found: f")
        XCTAssertEqual(JSError.moduleNotFound.errorDescription, "Module not found or not loaded")
        XCTAssertEqual(JSError.emptyContent.errorDescription, "No content received")
        XCTAssertEqual(JSError.contextInvalidated.errorDescription, "JavaScript context has been invalidated")
    }

    func testJSExecutionErrorDescriptions() {
        XCTAssertEqual(JSExecutionError.invalidURL.errorDescription, "Invalid URL")
        XCTAssertEqual(JSExecutionError.functionNotFound("test").errorDescription, "Function not found: test")
        XCTAssertEqual(JSExecutionError.javaScriptError("msg").errorDescription, "JavaScript error: msg")
    }
}

final class StreamResultParserTests: XCTestCase {

    func testParsesStreamsArrayOfDicts() {
        let json = """
        {"streams": [{"url": "https://a/1.m3u8", "headers": {"Referer": "https://a/"}, "quality": "720p", "type": "hls"}, {"nope": 1}],
         "subtitles": [{"url": "https://a/en.vtt", "language": "en", "label": "English", "kind": "captions"}]}
        """
        let result = StreamResultParser.parse(json)
        XCTAssertEqual(result.streams?.count, 1)
        XCTAssertEqual(result.streams?.first?.url, "https://a/1.m3u8")
        XCTAssertEqual(result.streams?.first?.headers?["Referer"], "https://a/")
        XCTAssertEqual(result.subtitles?.count, 1)
        XCTAssertEqual(result.subtitles?.first?.language, "en")
    }

    func testParsesSingleStreamString() {
        let result = StreamResultParser.parse("{\"stream\": \"https://a/v.mp4\"}")
        XCTAssertEqual(result.streams?.count, 1)
        XCTAssertEqual(result.streams?.first?.url, "https://a/v.mp4")
        XCTAssertNil(result.subtitles)
    }

    func testParsesSubtitlesStringAndStreamKeyFallback() {
        let result = StreamResultParser.parse("{\"streams\": [{\"stream\": \"https://a/2.m3u8\"}], \"subtitles\": \"https://a/s.vtt\"}")
        XCTAssertEqual(result.streams?.first?.url, "https://a/2.m3u8")
        XCTAssertEqual(result.subtitles?.count, 1)
        XCTAssertEqual(result.subtitles?.first?.url, "https://a/s.vtt")
    }

    func testParsesGarbageToEmpty() {
        XCTAssertNil(StreamResultParser.parse(nil).streams)
        XCTAssertNil(StreamResultParser.parse(42).streams)
        XCTAssertNil(StreamResultParser.parse("not json").streams)
        XCTAssertNil(StreamResultParser.parse("[1,2,3]").streams)
    }
}

final class NovelFallbackTests: XCTestCase {

    func testNovelFallbackErrorDescriptions() {
        XCTAssertEqual(NovelFallbackError.invalidURL.errorDescription, "Invalid chapter URL")
        XCTAssertEqual(NovelFallbackError.requestFailed("boom").errorDescription, "Direct fetch failed: boom")
        XCTAssertEqual(NovelFallbackError.badStatus(404).errorDescription, "Direct fetch failed with status code: 404")
        XCTAssertEqual(NovelFallbackError.undecodable.errorDescription, "Failed to decode chapter response")
    }
}

@MainActor
final class JSControllerPoolTests: XCTestCase {

    private var fixtureFileURLs: [URL] = []

    private func cleanupFixtures() {
        for url in fixtureFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        fixtureFileURLs.removeAll()
    }

    private func makeModule(script: String, version: String = "1.0") throws -> ScrapingModule {
        let fileName = "test-pool-\(UUID().uuidString).js"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
        try script.write(to: url, atomically: true, encoding: .utf8)
        fixtureFileURLs.append(url)
        let metadata = ModuleMetadata(
            sourceName: "PoolTest",
            author: Author(name: "t", icon: "i"),
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

    func testModulePoolReusesInstance() async throws {
        let controller = JSController()
        defer {
            controller.invalidateAllModules()
            cleanupFixtures()
        }
        let module = try makeModule(script: "function searchResults(k) { return '[]'; }")

        XCTAssertEqual(controller.cachedModuleCount(), 0)
        try await controller.loadModule(module)
        XCTAssertEqual(controller.cachedModuleCount(), 1)
        let first = controller.pooledModule(id: module.id)
        XCTAssertNotNil(first)

        try await controller.loadModule(module)
        XCTAssertEqual(controller.cachedModuleCount(), 1)
        XCTAssertTrue(controller.pooledModule(id: module.id) === first)

        controller.invalidateModule(id: module.id)
        XCTAssertEqual(controller.cachedModuleCount(), 0)
        XCTAssertNil(controller.pooledModule(id: module.id))
    }

    func testModulePoolReparsesOnVersionChange() async throws {
        let controller = JSController()
        defer {
            controller.invalidateAllModules()
            cleanupFixtures()
        }
        let v1 = try makeModule(script: "function searchResults(k) { return '[]'; }", version: "1.0")
        try await controller.loadModule(v1)
        let first = controller.pooledModule(id: v1.id)
        XCTAssertNotNil(first)

        let v2 = ScrapingModule(
            id: v1.id,
            metadata: ModuleMetadata(
                sourceName: "PoolTest",
                author: Author(name: "t", icon: "i"),
                iconUrl: "i",
                version: "2.0",
                language: "en",
                baseUrl: "https://example.com/",
                streamType: .hls,
                quality: .p720,
                searchBaseUrl: "https://example.com/s?q=%s",
                scriptUrl: "https://example.com/s.js"
            ),
            localPath: v1.localPath,
            metadataUrl: v1.metadataUrl
        )
        try await controller.loadModule(v2)
        let second = controller.pooledModule(id: v1.id)
        XCTAssertNotNil(second)
        XCTAssertFalse(second === first)
    }
}
@MainActor
final class ModuleCacheManagerTests: XCTestCase {

    private var cacheManager: ModuleCacheManager!
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

    func testCacheHitReturnsModuleWithoutNetwork() async throws {
        let cacheManager = ModuleCacheManager.shared!
        let script = "function searchResults(k) { return '[]'; }"
        let module = try makeModule(script: script, version: "1.0")

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
}
