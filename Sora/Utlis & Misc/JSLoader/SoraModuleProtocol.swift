//
//  SoraModuleProtocol.swift
//  Sora
//
//  Created by Sora Team on 12/09/26.
//

import Foundation
import JavaScriptCore
import os

@MainActor
public protocol SoraModule: Sendable {
    var metadata: ModuleMetadata { get }
    var scriptContent: String { get }
    var executionMode: ExecutionMode { get }

    func initialize() async throws
    func cleanup()
}

@MainActor
public final class SoraModuleInstance: SoraModule {
    public let metadata: ModuleMetadata
    public let scriptContent: String
    public let executionMode: ExecutionMode

    private let engine: SoraJSEngine
    private let bridge: JSBridge
    private let handler: JSExecutionModeHandler
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "ModuleInstance")
    private var isInitialized = false

    public init(metadata: ModuleMetadata, scriptContent: String) throws {
        self.metadata = metadata
        self.scriptContent = scriptContent
        self.executionMode = metadata.executionMode

        self.engine = SoraJSEngine()
        self.bridge = JSBridge(engine: engine)
        self.handler = ExecutionModeFactory.handler(for: executionMode)
    }

    public func initialize() async throws {
        guard !isInitialized else { return }

        logger.info("Initializing module: \(self.metadata.sourceName) [\(self.executionMode.rawValue)]")

        try engine.loadModuleScript(scriptContent, moduleName: metadata.sourceName)
        injectModuleGlobals()

        isInitialized = true
        logger.info("Module \(self.metadata.sourceName) initialized successfully")
    }

    private func injectModuleGlobals() {
        let baseUrl = metadata.baseUrl
        let searchBaseUrl = metadata.searchBaseUrl

        let config = JSValue(newObjectIn: engine.globalContext)
        config?.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        config?.setObject(searchBaseUrl, forKeyedSubscript: "searchBaseUrl" as NSString)
        config?.setObject(metadata.streamType.rawValue, forKeyedSubscript: "streamType" as NSString)
        config?.setObject(metadata.quality.rawValue, forKeyedSubscript: "quality" as NSString)
        config?.setObject(metadata.language, forKeyedSubscript: "language" as NSString)
        config?.setObject(metadata.version, forKeyedSubscript: "version" as NSString)
        engine.setGlobalObject(config, forKey: "soraConfig")

        let soraRequest = """
        function soraRequest(url, options = {}) {
            return new Promise(function(resolve, reject) {
                const finalOptions = {
                    method: options.method || 'GET',
                    headers: options.headers || {},
                    body: options.body || null,
                    encoding: options.encoding || 'utf-8',
                    timeout: options.timeout || 30000
                };
                // Native implementation injected by JSBridge
                soraRequestNative(url, finalOptions, resolve, reject);
            });
        }
        """
        engine.evaluateScript(soraRequest)
    }

    public func cleanup() {
        logger.info("Cleaning up module: \(self.metadata.sourceName)")
        engine.invalidate()
        isInitialized = false
    }

    public func search(keyword: String) async throws -> [SearchResult] {
        ensureInitialized()
        return try await handler.executeSearch(engine: engine, keyword: keyword)
    }

    public func details(url: String) async throws -> [MediaDetails] {
        ensureInitialized()
        return try await handler.executeDetails(engine: engine, url: url)
    }

    public func episodes(url: String) async throws -> [EpisodeLink] {
        ensureInitialized()
        return try await handler.executeEpisodes(engine: engine, url: url)
    }

    public func stream(url: String, html: String? = nil) async throws -> StreamResult {
        ensureInitialized()
        return try await handler.executeStream(engine: engine, url: url, html: html)
    }

    public func chapters(url: String) async throws -> [Chapter] {
        ensureInitialized()
        return try await handler.executeChapters(engine: engine, url: url)
    }

    public func chapterContent(url: String) async throws -> ChapterContent {
        ensureInitialized()
        return try await handler.executeChapterContent(engine: engine, url: url)
    }

    private func ensureInitialized() {
        if !isInitialized {
            fatalError("Module \(metadata.sourceName) not initialized. Call initialize() first.")
        }
    }
}

@MainActor
public final class SoraModuleRegistry: ObservableObject {
    @Published public private(set) var modules: [String: SoraModuleInstance] = [:]
    @Published public private(set) var activeModuleName: String?

    private let logger = os.Logger(subsystem: "com.sora.engine", category: "ModuleRegistry")

    public init() {}

    public func register(module: SoraModuleInstance) {
        let key = module.metadata.sourceName
        modules[key] = module
        logger.info("Registered module: \(key)")
    }

    public func unregister(moduleName: String) {
        modules.removeValue(forKey: moduleName)
        logger.info("Unregistered module: \(moduleName)")
    }

    public func getModule(named name: String) -> SoraModuleInstance? {
        return modules[name]
    }

    public func setActiveModule(_ module: SoraModuleInstance) {
        activeModuleName = module.metadata.sourceName
    }

    public func clearActiveModule() {
        activeModuleName = nil
    }

    public func activeModule() -> SoraModuleInstance? {
        guard let name = activeModuleName else { return nil }
        return modules[name]
    }

    public func initializeAll() async {
        for (name, module) in modules {
            do {
                try await module.initialize()
            } catch {
                logger.error("Failed to initialize module \(name): \(error)")
            }
        }
    }

    public func cleanupAll() {
        for (_, module) in modules {
            module.cleanup()
        }
        modules.removeAll()
    }
}

@MainActor
public final class SoraModuleLoader {
    private let session = URLSession.custom
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "ModuleLoader")

    public init() {}

    public func loadModule(from metadataUrl: String) async throws -> SoraModuleInstance {
        logger.info("Loading module from: \(metadataUrl)")

        guard let url = URL(string: metadataUrl) else {
            throw ModuleLoadError.invalidMetadataUrl
        }

        let (metadataData, _) = try await session.data(from: url)
        let metadata = try JSONDecoder().decode(ModuleMetadata.self, from: metadataData)

        guard let scriptUrl = URL(string: metadata.scriptUrl) else {
            throw ModuleLoadError.invalidScriptUrl
        }

        let (scriptData, _) = try await session.data(from: scriptUrl)
        guard let scriptContent = String(data: scriptData, encoding: .utf8) else {
            throw ModuleLoadError.invalidScriptEncoding
        }

        return try SoraModuleInstance(metadata: metadata, scriptContent: scriptContent)
    }

    public func loadModuleFromLocal(metadata: ModuleMetadata, localScriptPath: String) throws -> SoraModuleInstance {
        let localUrl = URL(fileURLWithPath: localScriptPath)
        let scriptContent = try String(contentsOf: localUrl, encoding: .utf8)
        return try SoraModuleInstance(metadata: metadata, scriptContent: scriptContent)
    }
}

public enum ModuleLoadError: Error, LocalizedError, Sendable {
    case invalidMetadataUrl
    case invalidScriptUrl
    case invalidScriptEncoding
    case initializationFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidMetadataUrl: return "Invalid metadata URL"
        case .invalidScriptUrl: return "Invalid script URL"
        case .invalidScriptEncoding: return "Invalid script encoding"
        case .initializationFailed(let err): return "Initialization failed: \(err.localizedDescription)"
        }
    }
}

@MainActor
public final class SoraModuleCoordinator {
    private let registry: SoraModuleRegistry
    private let loader: SoraModuleLoader
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "ModuleCoordinator")

    public init(registry: SoraModuleRegistry, loader: SoraModuleLoader) {
        self.registry = registry
        self.loader = loader
    }

    public convenience init() {
        self.init(registry: SoraModuleRegistry(), loader: SoraModuleLoader())
    }

    public func loadAndRegisterModule(from metadataUrl: String) async throws -> SoraModuleInstance {
        let module = try await loader.loadModule(from: metadataUrl)
        try await module.initialize()
        registry.register(module: module)
        return module
    }

    public func executeSearch(moduleName: String, keyword: String) async throws -> [SearchResult] {
        guard let module = registry.getModule(named: moduleName) else {
            throw CoordinationError.moduleNotFound(moduleName)
        }
        return try await module.search(keyword: keyword)
    }

    public func executeDetails(moduleName: String, url: String) async throws -> [MediaDetails] {
        guard let module = registry.getModule(named: moduleName) else {
            throw CoordinationError.moduleNotFound(moduleName)
        }
        return try await module.details(url: url)
    }

    public func executeEpisodes(moduleName: String, url: String) async throws -> [EpisodeLink] {
        guard let module = registry.getModule(named: moduleName) else {
            throw CoordinationError.moduleNotFound(moduleName)
        }
        return try await module.episodes(url: url)
    }

    public func executeStream(moduleName: String, url: String, html: String? = nil) async throws -> StreamResult {
        guard let module = registry.getModule(named: moduleName) else {
            throw CoordinationError.moduleNotFound(moduleName)
        }
        return try await module.stream(url: url, html: html)
    }

    public func executeChapters(moduleName: String, url: String) async throws -> [Chapter] {
        guard let module = registry.getModule(named: moduleName) else {
            throw CoordinationError.moduleNotFound(moduleName)
        }
        return try await module.chapters(url: url)
    }

    public func executeChapterContent(moduleName: String, url: String) async throws -> ChapterContent {
        guard let module = registry.getModule(named: moduleName) else {
            throw CoordinationError.moduleNotFound(moduleName)
        }
        return try await module.chapterContent(url: url)
    }

    public func getAvailableModules() -> [ModuleMetadata] {
        return registry.modules.values.map { $0.metadata }
    }

    public func unloadModule(named name: String) {
        registry.unregister(moduleName: name)
    }
}

public enum CoordinationError: Error, LocalizedError, Sendable {
    case moduleNotFound(String)
    case moduleNotInitialized(String)
    case executionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .moduleNotFound(let name): return "Module not found: \(name)"
        case .moduleNotInitialized(let name): return "Module not initialized: \(name)"
        case .executionFailed(let err): return "Execution failed: \(err.localizedDescription)"
        }
    }
}