//
//  JSController.swift
//  Sora
//
//  Created by Francesco on 05/01/25.
//  Refactored to use new SoraJSEngine architecture on 12/09/26.
//

import AVKit
import SwiftUI
import Foundation
import AVFoundation
import JavaScriptCore
import os.log

typealias Module = ScrapingModule

@MainActor
class JSController: NSObject, ObservableObject {
    static let shared = JSController()

    private let logger = os.Logger(subsystem: "com.sora.controller", category: "JSController")

    private var engine: SoraJSEngine?
    private var bridge: JSBridge?
    private var currentModule: SoraModuleInstance?
    private var coordinator: SoraModuleCoordinator
    private var modulePool: [UUID: SoraModuleInstance] = [:]
    private var modulePoolOrder: [UUID] = []
    private var currentModuleId: UUID?
    private let maxPooledModules = 8
    private var moduleRemovedObserver: NSObjectProtocol?
    private var inflightOperations: [UUID: Task<Void, Never>] = [:]
    private var moduleGeneration: UInt64 = 0
    private var pendingRequests: [String: Any] = [:]

    @Published var savedAssets: [DownloadedAsset] = []
    @Published var activeDownloads: [JSActiveDownload] = []
    var activeDownloadMap: [URLSessionTask: UUID] = [:]
    @Published var downloadQueue: [JSActiveDownload] = []
    var isProcessingQueue: Bool = false

    var maxConcurrentDownloads: Int {
        UserDefaults.standard.object(forKey: "maxConcurrentDownloads") as? Int ?? 3
    }

    var cancelledDownloadIDs: Set<UUID> = []
    var downloadURLSession: AVAssetDownloadURLSession?
    var mp4ProgressObservations: [UUID: NSKeyValueObservation]?
    var mp4CustomSessions: [UUID: URLSession]?

    var currentContext: JSContext? {
        engine?.globalContext
    }

    var context: JSContext? {
        engine?.globalContext
    }

    override init() {
        self.coordinator = SoraModuleCoordinator()
        super.init()
        initializeEngine()
        loadSavedAssets()
        moduleRemovedObserver = NotificationCenter.default.addObserver(
            forName: .moduleRemoved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let idString = note.object as? String,
                  let id = UUID(uuidString: idString) else { return }
            Task { @MainActor [weak self] in
                self?.invalidateModule(id: id)
            }
        }
    }

    deinit {
        if let token = moduleRemovedObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func initializeEngine() {
        engine = SoraJSEngine { [weak self] ctx, exception in
            self?.handleJSException(ctx, exception)
        }
        bridge = JSBridge(engine: engine!)
    }

    nonisolated private func handleJSException(_ ctx: JSContext, _ exception: JSValue?) {
        let message = exception?.toString() ?? "Unknown JavaScript exception"
        let stackTrace = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
        logger.error("JS Exception: \(message)\nStack: \(stackTrace)")
    }

    func loadModule(_ module: ScrapingModule) async throws {
        moduleGeneration &+= 1
        let currentGen = moduleGeneration
        let scriptContent = try ModuleManager.shared.getModuleContent(module)

        if let cached = modulePool[module.id],
           cached.metadata.version == module.metadata.version,
       cached.scriptContent == scriptContent {
            currentModule = cached
            currentModuleId = module.id
            return
        }

        logger.info("Loading module: \(module.metadata.sourceName)")

        do {
            let instance = try SoraModuleInstance(metadata: module.metadata, scriptContent: scriptContent)
            try await instance.initialize()
            try checkGeneration(currentGen)
            currentModule = instance
            currentModuleId = module.id
            storeInPool(instance, id: module.id)
            logger.info("Module \(module.metadata.sourceName) loaded successfully")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Failed to load module \(module.metadata.sourceName): \(error)")
            throw error
        }
    }

    private func checkGeneration(_ gen: UInt64) throws {
        guard gen == moduleGeneration else {
            throw CancellationError()
        }
    }

    @discardableResult
    private func withGeneration<T>(_ gen: UInt64, _ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try checkGeneration(gen)
        return try await operation()
    }

    private func storeInPool(_ instance: SoraModuleInstance, id: UUID) {
    modulePool[id] = instance
    modulePoolOrder.removeAll { $0 == id }
    modulePoolOrder.append(id)
    while modulePoolOrder.count > maxPooledModules, let oldest = modulePoolOrder.first {
        modulePoolOrder.removeFirst()
        modulePool[oldest]?.cleanup()
        modulePool.removeValue(forKey: oldest)
    }
}

    func invalidateModule(id: UUID) {
        modulePool[id]?.cleanup()
        modulePool.removeValue(forKey: id)
        modulePoolOrder.removeAll { $0 == id }
        if currentModuleId == id {
            currentModule = nil
            currentModuleId = nil
        }
        moduleGeneration &+= 1
}

    func invalidateAllModules() {
        for (_, instance) in modulePool {
            instance.cleanup()
        }
        modulePool.removeAll()
        modulePoolOrder.removeAll()
        currentModule = nil
        currentModuleId = nil
    }

    func cachedModuleCount() -> Int {
    modulePool.count
}

    func pooledModule(id: UUID) -> SoraModuleInstance? {
    modulePool[id]
}

    private func deduplicate<T: Sendable>(key: String, factory: @escaping @Sendable () async throws -> T) async throws -> T {
    let keyWithType = "\(key)|\(String(describing: T.self))"
    if let existing = pendingRequests[keyWithType] as? Task<T, Error> {
        return try await existing.value
    }
    let task = Task { try await factory() }
    pendingRequests[keyWithType] = task
    defer { pendingRequests.removeValue(forKey: keyWithType) }
    return try await task.value
}

    func loadScript(_ script: String) {
        guard let engine = engine else { return }
        let result = engine.evaluateScript(script)
        if let exception = engine.globalContext.exception {
            logger.error("Error loading script: \(exception)")
        engine.globalContext.exception = nil
        }
    }

    func setupContext() {
        guard let engine = engine else { return }
        engine.evaluateScript("""
            function extractChaptersWithCallback(href, callback) {
                try {
                    console.log('[JS] extractChaptersWithCallback called with href:', href);
                    var result = extractChapters(href);
                    if (result && typeof result.then === 'function') {
                        result.then(function(arr) {
                            console.log('[JS] extractChaptersWithCallback Promise resolved, arr.length:', arr && arr.length);
                            callback(arr);
                        }).catch(function(e) {
                            console.log('[JS] extractChaptersWithCallback Promise rejected:', e);
                            callback([]);
                        });
                    } else {
                        console.log('[JS] extractChaptersWithCallback result is not a Promise:', result);
                        callback(result);
                    }
                } catch (e) {
                    console.log('[JS] extractChaptersWithCallback threw:', e);
                    callback([]);
                }
            }
            """)
    }

    func fetchStreamUrl(episodeUrl: String, softsub: Bool = false, module: ScrapingModule, completion: @escaping ((streams: [String]?, subtitles: [String]?, sources: [[String:Any]]? )) -> Void) {
    let gen = moduleGeneration
    let key = "stream|\(episodeUrl)|\(module.id)|\(softsub)"
    Task { @MainActor in
        do {
            let result: (streams: [String], subtitles: [String], sources: [[String: Any]]) = try await withGeneration(gen) {
                try await deduplicate(key: key) { @MainActor in
                    try await self.loadModule(module)
                    guard let currentModule = self.currentModule else { throw CancellationError() }
                    let result = try await self.currentModule!.stream(url: episodeUrl)
                    let streams = result.streams?.map { $0.url } ?? []
                    let subtitles = result.subtitles?.map { $0.url } ?? []
                    let sources = result.streams?.map { [
                        "url": $0.url,
                        "headers": $0.headers ?? [:],
                        "quality": $0.quality ?? "",
                        "type": $0.type ?? ""
                    ] } ?? []
                    return (streams, subtitles, sources)
                }
            }
            completion(result)
        } catch is CancellationError {
        } catch {
            completion((nil, nil, nil))
        }
    }
}

    func fetchStreamUrlJS(episodeUrl: String, softsub: Bool = false, module: ScrapingModule, completion: @escaping ((streams: [String]?, subtitles: [String]?,sources: [[String:Any]]? )) -> Void) {
    fetchStreamUrl(episodeUrl: episodeUrl, softsub: softsub, module: module, completion: completion)
}

    func fetchStreamUrlJSSecond(episodeUrl: String, softsub: Bool = false, module: ScrapingModule, completion: @escaping ((streams: [String]?, subtitles: [String]?,sources: [[String:Any]]? )) -> Void) {
    fetchStreamUrl(episodeUrl: episodeUrl, softsub: softsub, module: module, completion: completion)
}

    func fetchDetails(url: String, completion: @escaping ([MediaItem], [EpisodeLink]) -> Void) {
    let gen = moduleGeneration
    Task { @MainActor in
        do {
            let (mediaItems, episodeLinks) = try await withGeneration(gen) {
                try await deduplicate(key: "details|\(url)") { @MainActor in
                    guard let currentModule = self.currentModule else { throw CancellationError() }
                    let details = try await currentModule.details(url: url)
                    let episodes = try await currentModule.episodes(url: url)

                    let mediaItems = details.map { detail in
                        MediaItem(
                            description: detail.description,
                            aliases: detail.aliases,
                            airdate: detail.airdate
                        )
                    }

                    let episodeLinks = episodes.map { ep in
                        EpisodeLink(
                            id: ep.id,
                            number: ep.number,
                            title: ep.title,
                            href: ep.href,
                            duration: ep.duration
                        )
                    }
                    return (mediaItems, episodeLinks)
                }
            }
            completion(mediaItems, episodeLinks)
        } catch is CancellationError {
        } catch {
            completion([], [])
        }
        }
    }

    func fetchDetailsJS(url: String, completion: @escaping ([MediaItem], [EpisodeLink]) -> Void) {
    fetchDetails(url: url, completion: completion)
}

    func fetchSearchResults(keyword: String, module: ScrapingModule, completion: @escaping ([SearchItem]) -> Void) {
    let gen = moduleGeneration
    Task { @MainActor in
        do {
            let items = try await deduplicate(key: "search|\(keyword)|\(module.id)") { @MainActor in
                try await self.loadModule(module)
                guard let currentModule = self.currentModule else { throw CancellationError() }
                let results = try await currentModule.search(keyword: keyword)
                return results.map { SearchItem(title: $0.title, imageUrl: $0.image, href: $0.href) }
            }
            completion(items)
        } catch is CancellationError {
        } catch {
            completion([])
        }
        }
    }

    private func fetchSearchResultsAsync(keyword: String, module: ScrapingModule, completion: @escaping ([SearchItem]) -> Void) async {
    let key = "search|\(keyword)|\(module.id)"
    do {
        let items = try await deduplicate(key: key) { @MainActor in
            try await self.loadModule(module)
            guard let currentModule = self.currentModule else { throw CancellationError() }
            let results = try await currentModule.search(keyword: keyword)
            return results.map { SearchItem(title: $0.title, imageUrl: $0.image, href: $0.href) }
        }
        completion(items)
    } catch {
        completion([])
    }
}

    func fetchJsSearchResults(keyword: String, module: ScrapingModule, completion: @escaping ([SearchItem]) -> Void) {
    fetchSearchResults(keyword: keyword, module: module, completion: completion)
}

    @MainActor func extractChapters(moduleId: UUID, href: String, completion: @escaping ([[String: Any]]) -> Void) {
    let gen = moduleGeneration
    Task { @MainActor in
        do {
            try await withGeneration(gen) {
                await extractChaptersAsync(moduleId: moduleId, href: href, completion: completion)
            }
        } catch is CancellationError {
        } catch {
            completion([])
        }
        }
    }

    private func extractChaptersAsync(moduleId: UUID, href: String, completion: @escaping ([[String: Any]]) -> Void) async {
    guard let currentModule = self.currentModule else {
        completion([])
        return
    }

    do {
        let chapters = try await currentModule.chapters(url: href)
        let result = chapters.map { chapter in
            [
                "number": chapter.number,
                "title": chapter.title,
                "href": chapter.href,
                "updatedAt": chapter.updatedAt?.timeIntervalSince1970 ?? 0
            ]
        }
        completion(result)
    } catch {
        logger.error("extractChapters failed: \(error)")
        completion([])
    }
}

    @MainActor func extractText(moduleId: UUID, href: String, completion: @escaping (Result<String, Error>) -> Void) {
    let gen = moduleGeneration
    Task { @MainActor in
        do {
            try await withGeneration(gen) {
                await extractTextAsync(moduleId: moduleId, href: href, completion: completion)
            }
        } catch is CancellationError {
        } catch {
            completion(.failure(error))
        }
        }
    }

    private func extractTextAsync(moduleId: UUID, href: String, completion: @escaping (Result<String, Error>) -> Void) async {
    guard let currentModule = self.currentModule else {
        completion(.failure(JSError.moduleNotFound))
        return
    }

    do {
        let content = try await currentModule.chapterContent(url: href)
        completion(.success(content.html))
    } catch {
        logger.error("extractText failed, trying native fallback: \(error)")
        do {
            let fallback = try await NovelContentFallback.fetchDirectContent(from: href)
            completion(.success(fallback))
        } catch {
            completion(.failure(error))
        }
    }
}

    func updateMaxConcurrentDownloads(_ newLimit: Int) {
    if !downloadQueue.isEmpty && !isProcessingQueue {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.objectWillChange.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.processDownloadQueue()
            }
        }
    }
}

    private func setupDownloadSession() {
    if downloadURLSession == nil {
        Task {
            initializeDownloadSession()
            setupDownloadFunction()
        }
    }
}

    func invalidateCurrentModule() {
    if let id = currentModuleId {
        invalidateModule(id: id)
    } else {
        currentModule?.cleanup()
        currentModule = nil
    }
}
}
