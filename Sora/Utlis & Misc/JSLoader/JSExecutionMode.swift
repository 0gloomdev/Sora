//
//  JSExecutionMode.swift
//  Sora
//
//  Created by Sora Team on 12/09/26.
//

import Foundation
import JavaScriptCore
import os

@MainActor
public protocol JSExecutionModeHandler: Sendable {
    var mode: ExecutionMode { get }
    func executeSearch(engine: SoraJSEngine, keyword: String) async throws -> [SearchResult]
    func executeDetails(engine: SoraJSEngine, url: String) async throws -> [MediaDetails]
    func executeEpisodes(engine: SoraJSEngine, url: String) async throws -> [EpisodeLink]
    func executeStream(engine: SoraJSEngine, url: String, html: String?) async throws -> StreamResult
    func executeChapters(engine: SoraJSEngine, url: String) async throws -> [Chapter]
    func executeChapterContent(engine: SoraJSEngine, url: String) async throws -> ChapterContent
}

@MainActor
public final class NormalModeHandler: JSExecutionModeHandler {
    public let mode: ExecutionMode = .normal
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "NormalMode")
    private let session = URLSession.custom

    public init() {}

    public func executeSearch(engine: SoraJSEngine, keyword: String) async throws -> [SearchResult] {
        let searchUrl = buildSearchUrl(keyword: keyword)
        let html = try await fetchHTML(url: searchUrl)
        return try await executeJSFunction(engine: engine, name: "searchResults", args: [html])
    }

    public func executeDetails(engine: SoraJSEngine, url: String) async throws -> [MediaDetails] {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractDetails", args: [html])
    }

    public func executeEpisodes(engine: SoraJSEngine, url: String) async throws -> [EpisodeLink] {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractEpisodes", args: [html])
    }

    public func executeStream(engine: SoraJSEngine, url: String, html: String?) async throws -> StreamResult {
        let htmlContent: String
        if let html {
            htmlContent = html
        } else {
            htmlContent = try await fetchHTML(url: url)
        }
        let result = try await executeJSRawString(engine: engine, name: "extractStreamUrl", args: [htmlContent])
        return StreamResultParser.parse(result)
    }

    public func executeChapters(engine: SoraJSEngine, url: String) async throws -> [Chapter] {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractChapters", args: [html])
    }

    public func executeChapterContent(engine: SoraJSEngine, url: String) async throws -> ChapterContent {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractText", args: [html])
    }

    private func buildSearchUrl(keyword: String) -> String {
        // This would be injected from module metadata
        return "https://example.com/search?q=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    }

    private func fetchHTML(url: String) async throws -> String {
        guard let url = URL(string: url) else { throw JSExecutionError.invalidURL }
        let (data, _) = try await session.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { throw JSExecutionError.decodeFailed }
        return html
    }

    private func executeJSFunction<T: Decodable>(engine: SoraJSEngine, name: String, args: [Any]) async throws -> T {
        guard let fn = engine.globalContext.objectForKeyedSubscript(name) else {
            throw JSExecutionError.functionNotFound(name)
        }

        let result = fn.call(withArguments: args)
        if let exception = engine.globalContext.exception {
            let msg = exception.toString() ?? "Unknown JS error"
            engine.globalContext.exception = nil
            throw JSExecutionError.javaScriptError(msg)
        }

        guard let result = result, !result.isNull, !result.isUndefined else {
            throw JSExecutionError.nullResult
        }

        let jsonString = result.toString() ?? "[]"
        guard let data = jsonString.data(using: .utf8) else {
            throw JSExecutionError.invalidJSON
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode \(T.self): \(error)")
            throw JSExecutionError.decodingFailed(error)
        }
    }

    private func executeJSRawString(engine: SoraJSEngine, name: String, args: [Any]) async throws -> String {
        guard let fn = engine.globalContext.objectForKeyedSubscript(name) else {
            throw JSExecutionError.functionNotFound(name)
        }

        let result = fn.call(withArguments: args)
        if let exception = engine.globalContext.exception {
            let msg = exception.toString() ?? "Unknown JS error"
            engine.globalContext.exception = nil
            throw JSExecutionError.javaScriptError(msg)
        }

        guard let result = result, !result.isNull, !result.isUndefined,
              let string = result.toString() else {
            throw JSExecutionError.nullResult
        }
        return string
    }
}

/// Single shared parser for module stream results (`extractStreamUrl` output).
/// Handles: `{streams: [{url/headers/...}]}` | `{stream: url}` | legacy
/// `[url, ...]` arrays | `{subtitles: ...}` as array-of-dicts or plain string.
struct StreamResultParser {
    static func parse(_ result: Any?) -> StreamResult {
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return StreamResult()
        }

        var streams: [StreamSource]? = nil
        var subtitles: [SubtitleTrack]? = nil

        if let streamsArray = json["streams"] as? [[String: Any]] {
            streams = streamsArray.compactMap { dict in
                guard let url = dict["url"] as? String ?? dict["stream"] as? String else { return nil }
                return StreamSource(
                    url: url,
                    headers: dict["headers"] as? [String: String],
                    quality: dict["quality"] as? String,
                    type: dict["type"] as? String
                )
            }
        } else if let streamUrl = json["stream"] as? String {
            streams = [StreamSource(url: streamUrl)]
        }

        if let subsArray = json["subtitles"] as? [[String: Any]] {
            subtitles = subsArray.compactMap { dict in
                guard let url = dict["url"] as? String ?? dict["file"] as? String else { return nil }
                return SubtitleTrack(
                    url: url,
                    language: dict["language"] as? String,
                    label: dict["label"] as? String,
                    kind: dict["kind"] as? String
                )
            }
        } else if let subUrl = json["subtitles"] as? String {
            subtitles = [SubtitleTrack(url: subUrl)]
        }

        return StreamResult(streams: streams, subtitles: subtitles)
    }
}

@MainActor
public final class AsyncModeHandler: JSExecutionModeHandler {
    public let mode: ExecutionMode = .async
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "AsyncMode")
    private let session = URLSession.custom

    public init() {}

    public func executeSearch(engine: SoraJSEngine, keyword: String) async throws -> [SearchResult] {
        return try await executeAsyncFunction(engine: engine, name: "searchResults", args: [keyword])
    }

    public func executeDetails(engine: SoraJSEngine, url: String) async throws -> [MediaDetails] {
        return try await executeAsyncFunction(engine: engine, name: "extractDetails", args: [url])
    }

    public func executeEpisodes(engine: SoraJSEngine, url: String) async throws -> [EpisodeLink] {
        return try await executeAsyncFunction(engine: engine, name: "extractEpisodes", args: [url])
    }

    public func executeStream(engine: SoraJSEngine, url: String, html: String?) async throws -> StreamResult {
        return try await executeAsyncStreamFunction(engine: engine, url: url)
    }

    public func executeChapters(engine: SoraJSEngine, url: String) async throws -> [Chapter] {
        return try await executeAsyncFunction(engine: engine, name: "extractChapters", args: [url])
    }

    public func executeChapterContent(engine: SoraJSEngine, url: String) async throws -> ChapterContent {
        return try await executeAsyncFunction(engine: engine, name: "extractText", args: [url])
    }

    private func executeAsyncFunction<T: Decodable>(engine: SoraJSEngine, name: String, args: [Any]) async throws -> T {
        guard let fn = engine.globalContext.objectForKeyedSubscript(name) else {
            throw JSExecutionError.functionNotFound(name)
        }

        let promiseValue = fn.call(withArguments: args)
        guard let promise = promiseValue, promise.hasProperty("then") else {
            throw JSExecutionError.notAPromise
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = JSPromiseBox(continuation)
            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                Task { @MainActor in
                    do {
                        let value = try self.parseResult(result, as: T.self)
                        box.resume(returning: value)
                    } catch {
                        box.resume(throwing: error)
                    }
                }
            }

            let catchBlock: @convention(block) (JSValue) -> Void = { error in
                Task { @MainActor in
                    let msg = error.toString() ?? "Promise rejected"
                    box.resume(throwing: JSExecutionError.javaScriptError(msg))
                }
            }

            let thenFn = JSValue(object: thenBlock, in: engine.globalContext)
            let catchFn = JSValue(object: catchBlock, in: engine.globalContext)

            promise.invokeMethod("then", withArguments: [thenFn as Any])
            promise.invokeMethod("catch", withArguments: [catchFn as Any])
        }
    }

    private func executeAsyncStreamFunction(engine: SoraJSEngine, url: String) async throws -> StreamResult {
        guard let fn = engine.globalContext.objectForKeyedSubscript("extractStreamUrl") else {
            throw JSExecutionError.functionNotFound("extractStreamUrl")
        }

        let promiseValue = fn.call(withArguments: [url])
        guard let promise = promiseValue, promise.hasProperty("then") else {
            throw JSExecutionError.notAPromise
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = JSPromiseBox(continuation)
            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                Task { @MainActor in
                    let streamResult = StreamResultParser.parse(result.toString())
                    box.resume(returning: streamResult)
                }
            }

            let catchBlock: @convention(block) (JSValue) -> Void = { error in
                Task { @MainActor in
                    let msg = error.toString() ?? "Promise rejected"
                    box.resume(throwing: JSExecutionError.javaScriptError(msg))
                }
            }

            let thenFn = JSValue(object: thenBlock, in: engine.globalContext)
            let catchFn = JSValue(object: catchBlock, in: engine.globalContext)

            promise.invokeMethod("then", withArguments: [thenFn as Any])
            promise.invokeMethod("catch", withArguments: [catchFn as Any])
        }
    }

    private func parseResult<T: Decodable>(_ result: JSValue, as type: T.Type) throws -> T {
        if let jsonString = result.toString(),
           let data = jsonString.data(using: .utf8) {
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw JSExecutionError.invalidJSON
    }
}

@MainActor
public final class StreamAsyncModeHandler: JSExecutionModeHandler {
    public let mode: ExecutionMode = .streamAsync
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "StreamAsyncMode")
    private let session = URLSession.custom

    public init() {}

    public func executeSearch(engine: SoraJSEngine, keyword: String) async throws -> [SearchResult] {
        let searchUrl = buildSearchUrl(keyword: keyword)
        let html = try await fetchHTML(url: searchUrl)
        return try await executeJSFunction(engine: engine, name: "searchResults", args: [html])
    }

    public func executeDetails(engine: SoraJSEngine, url: String) async throws -> [MediaDetails] {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractDetails", args: [html])
    }

    public func executeEpisodes(engine: SoraJSEngine, url: String) async throws -> [EpisodeLink] {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractEpisodes", args: [html])
    }

    public func executeStream(engine: SoraJSEngine, url: String, html: String?) async throws -> StreamResult {
        let htmlContent: String
        if let html {
            htmlContent = html
        } else {
            htmlContent = try await fetchHTML(url: url)
        }
        return try await executeAsyncStreamFunction(engine: engine, html: htmlContent)
    }

    public func executeChapters(engine: SoraJSEngine, url: String) async throws -> [Chapter] {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractChapters", args: [html])
    }

    public func executeChapterContent(engine: SoraJSEngine, url: String) async throws -> ChapterContent {
        let html = try await fetchHTML(url: url)
        return try await executeJSFunction(engine: engine, name: "extractText", args: [html])
    }

    private func buildSearchUrl(keyword: String) -> String {
        return "https://example.com/search?q=\(keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
    }

    private func fetchHTML(url: String) async throws -> String {
        guard let url = URL(string: url) else { throw JSExecutionError.invalidURL }
        let (data, _) = try await session.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { throw JSExecutionError.decodeFailed }
        return html
    }

    private func executeJSFunction<T: Decodable>(engine: SoraJSEngine, name: String, args: [Any]) async throws -> T {
        guard let fn = engine.globalContext.objectForKeyedSubscript(name) else {
            throw JSExecutionError.functionNotFound(name)
        }

        let result = fn.call(withArguments: args)
        if let exception = engine.globalContext.exception {
            let msg = exception.toString() ?? "Unknown JS error"
            engine.globalContext.exception = nil
            throw JSExecutionError.javaScriptError(msg)
        }

        guard let result = result, !result.isNull, !result.isUndefined else {
            throw JSExecutionError.nullResult
        }

        let jsonString = result.toString() ?? "[]"
        guard let data = jsonString.data(using: .utf8) else {
            throw JSExecutionError.invalidJSON
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode \(T.self): \(error)")
            throw JSExecutionError.decodingFailed(error)
        }
    }

    private func executeAsyncStreamFunction(engine: SoraJSEngine, html: String) async throws -> StreamResult {
        guard let fn = engine.globalContext.objectForKeyedSubscript("extractStreamUrl") else {
            throw JSExecutionError.functionNotFound("extractStreamUrl")
        }

        let promiseValue = fn.call(withArguments: [html])
        guard let promise = promiseValue, promise.hasProperty("then") else {
            throw JSExecutionError.notAPromise
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = JSPromiseBox(continuation)
            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                Task { @MainActor in
                    let streamResult = StreamResultParser.parse(result.toString())
                    box.resume(returning: streamResult)
                }
            }

            let catchBlock: @convention(block) (JSValue) -> Void = { error in
                Task { @MainActor in
                    let msg = error.toString() ?? "Promise rejected"
                    box.resume(throwing: JSExecutionError.javaScriptError(msg))
                }
            }

            let thenFn = JSValue(object: thenBlock, in: engine.globalContext)
            let catchFn = JSValue(object: catchBlock, in: engine.globalContext)

            promise.invokeMethod("then", withArguments: [thenFn as Any])
            promise.invokeMethod("catch", withArguments: [catchFn as Any])
        }
    }
}

@MainActor
public final class SoftSubsModeHandler: JSExecutionModeHandler {
    public let mode: ExecutionMode = .softSubs
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "SoftSubsMode")
    private let session = URLSession.custom

    public init() {}

    public func executeSearch(engine: SoraJSEngine, keyword: String) async throws -> [SearchResult] {
        let asyncHandler = AsyncModeHandler()
        return try await asyncHandler.executeSearch(engine: engine, keyword: keyword)
    }

    public func executeDetails(engine: SoraJSEngine, url: String) async throws -> [MediaDetails] {
        let asyncHandler = AsyncModeHandler()
        return try await asyncHandler.executeDetails(engine: engine, url: url)
    }

    public func executeEpisodes(engine: SoraJSEngine, url: String) async throws -> [EpisodeLink] {
        let asyncHandler = AsyncModeHandler()
        return try await asyncHandler.executeEpisodes(engine: engine, url: url)
    }

    public func executeStream(engine: SoraJSEngine, url: String, html: String?) async throws -> StreamResult {
        let htmlContent: String
        if let html {
            htmlContent = html
        } else {
            htmlContent = try await fetchHTML(url: url)
        }
        return try await executeAsyncStreamFunction(engine: engine, html: htmlContent)
    }

    public func executeChapters(engine: SoraJSEngine, url: String) async throws -> [Chapter] {
        let asyncHandler = AsyncModeHandler()
        return try await asyncHandler.executeChapters(engine: engine, url: url)
    }

    public func executeChapterContent(engine: SoraJSEngine, url: String) async throws -> ChapterContent {
        let asyncHandler = AsyncModeHandler()
        return try await asyncHandler.executeChapterContent(engine: engine, url: url)
    }

    private func fetchHTML(url: String) async throws -> String {
        guard let url = URL(string: url) else { throw JSExecutionError.invalidURL }
        let (data, _) = try await session.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { throw JSExecutionError.decodeFailed }
        return html
    }

    private func executeAsyncStreamFunction(engine: SoraJSEngine, html: String) async throws -> StreamResult {
        guard let fn = engine.globalContext.objectForKeyedSubscript("extractStreamUrl") else {
            throw JSExecutionError.functionNotFound("extractStreamUrl")
        }

        let promiseValue = fn.call(withArguments: [html])
        guard let promise = promiseValue, promise.hasProperty("then") else {
            throw JSExecutionError.notAPromise
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = JSPromiseBox(continuation)
            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                Task { @MainActor in
                    let streamResult = StreamResultParser.parse(result.toString())
                    box.resume(returning: streamResult)
                }
            }

            let catchBlock: @convention(block) (JSValue) -> Void = { error in
                Task { @MainActor in
                    let msg = error.toString() ?? "Promise rejected"
                    box.resume(throwing: JSExecutionError.javaScriptError(msg))
                }
            }

            let thenFn = JSValue(object: thenBlock, in: engine.globalContext)
            let catchFn = JSValue(object: catchBlock, in: engine.globalContext)

            promise.invokeMethod("then", withArguments: [thenFn as Any])
            promise.invokeMethod("catch", withArguments: [catchFn as Any])
        }
    }
}

public enum JSExecutionError: Error, LocalizedError, Sendable {
    case invalidURL
    case decodeFailed
    case functionNotFound(String)
    case javaScriptError(String)
    case nullResult
    case notAPromise
    case invalidJSON
    case decodingFailed(Error)
    case timedOut(Double)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .decodeFailed: return "Failed to decode response"
        case .functionNotFound(let name): return "Function not found: \(name)"
        case .javaScriptError(let msg): return "JavaScript error: \(msg)"
        case .nullResult: return "JavaScript function returned null/undefined"
        case .notAPromise: return "Expected a Promise but got something else"
        case .invalidJSON: return "Invalid JSON response"
        case .decodingFailed(let err): return "Decoding failed: \(err.localizedDescription)"
        case .timedOut(let seconds): return "JavaScript promise timed out after \(seconds)s"
        }
    }
}

/// Resume-once box with a cancellable deadline for JS promise waits.
/// A hanging module promise must never hang the awaiting Swift task forever,
/// and a late promise settlement after timeout must not trap on double-resume.
final class JSPromiseBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var deadline: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<T, Error>, timeout seconds: Double = JSExecutionPolicy.asyncTimeoutSeconds) {
        self.continuation = continuation
        let item = DispatchWorkItem { [weak self] in
            self?.resume(throwing: JSExecutionError.timedOut(seconds))
        }
        self.deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func resume(returning value: T) {
        settle { $0.resume(returning: value) }
    }

    func resume(throwing error: Error) {
        settle { $0.resume(throwing: error) }
    }

    private func settle(_ fn: (CheckedContinuation<T, Error>) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let cont = continuation else { return }
        continuation = nil
        deadline?.cancel()
        deadline = nil
        fn(cont)
    }
}

enum JSExecutionPolicy {
    /// Seconds before a pending module promise fails with `timedOut`.
    static var asyncTimeoutSeconds: Double = 30
}

@MainActor
public final class ExecutionModeFactory {
    public static func handler(for mode: ExecutionMode) -> JSExecutionModeHandler {
        switch mode {
        case .normal: return NormalModeHandler()
        case .async: return AsyncModeHandler()
        case .streamAsync: return StreamAsyncModeHandler()
        case .softSubs: return SoftSubsModeHandler()
        }
    }
}
