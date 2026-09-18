//
//  SoraJSEngine.swift
//  Sora
//
//  Created by Sora Team on 12/09/26.
//

import Foundation
import JavaScriptCore
import os

@MainActor
public final class SoraJSEngine: @unchecked Sendable {
    private let context: JSContext
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "JSEngine")
    private var isContextValid = true
    private let exceptionHandler: (@Sendable (JSContext, JSValue?) -> Void)?
    /// Mirrors the last JS exception. JavaScriptCore does NOT populate
    /// `context.exception` when an `exceptionHandler` is set, so we track it.
    private var lastException: JSValue?
    private var timerTasks: [Double: DispatchWorkItem] = [:]
    private var nextTimerId: Double = 0

    public init(exceptionHandler: (@Sendable (JSContext, JSValue?) -> Void)? = nil) {
        self.exceptionHandler = exceptionHandler
        self.context = JSContext()
        setupContext()
    }

    deinit {
        // Cleanup without calling MainActor-isolated methods
        context.exceptionHandler = nil
    }

    private func setupContext() {
        context.exceptionHandler = { [weak self] ctx, exception in
            guard let ctx = ctx else { return }
            self?.lastException = exception
            ctx.exception = exception
            self?.handleException(ctx, exception)
        }
        setupBaseEnvironment()
    }

    private func setupBaseEnvironment() {
        setupConsole()
        setupTimerPolyfills()
        setupGlobalPolyfills()
    }

    private func setupConsole() {
        let console = JSValue(newObjectIn: context)
        let logFn: @convention(block) (String) -> Void = { [weak self] message in
            self?.logger.debug("JS Console: \(message)")
        }
        let errorFn: @convention(block) (String) -> Void = { [weak self] message in
            self?.logger.error("JS Error: \(message)")
        }
        let warnFn: @convention(block) (String) -> Void = { [weak self] message in
            self?.logger.warning("JS Warning: \(message)")
        }
        console?.setObject(logFn, forKeyedSubscript: "log" as NSString)
        console?.setObject(errorFn, forKeyedSubscript: "error" as NSString)
        console?.setObject(warnFn, forKeyedSubscript: "warn" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func setupGlobalPolyfills() {
        let polyfills = """
        if (typeof globalThis === 'undefined') { globalThis = this; }
        if (typeof Buffer === 'undefined') { Buffer = function() {}; }
        if (typeof process === 'undefined') { process = { env: {}, nextTick: function(fn) { setTimeout(fn, 0); } }; }
        if (typeof setImmediate === 'undefined') { setImmediate = function(fn) { setTimeout(fn, 0); }; }
        if (typeof clearImmediate === 'undefined') { clearImmediate = clearTimeout; }
        """
        context.evaluateScript(polyfills)
    }

    private func setupTimerPolyfills() {
        let setTimeoutBlock: @convention(block) (JSValue, Double) -> Double = { [weak self] fn, ms in
            guard let self = self else { return 0 }
            return MainActor.assumeIsolated {
                self.nextTimerId += 1
                let id = self.nextTimerId
                let delay = max(0, ms) / 1000.0
                var workItem: DispatchWorkItem!
                workItem = DispatchWorkItem { [weak self] in
                    fn.call(withArguments: [])
                    guard let self = self else { return }
                    MainActor.assumeIsolated {
                        self.timerTasks.removeValue(forKey: id)
                    }
                }
                self.timerTasks[id] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
                return id
            }
        }

        let clearTimeoutBlock: @convention(block) (Double) -> Void = { [weak self] id in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                if let item = self.timerTasks.removeValue(forKey: id) {
                    item.cancel()
                }
            }
        }

        let setIntervalBlock: @convention(block) (JSValue, Double) -> Double = { [weak self] fn, ms in
            guard let self = self else { return 0 }
            return MainActor.assumeIsolated {
                self.nextTimerId += 1
                let id = self.nextTimerId
                let interval = max(0, ms) / 1000.0
                var scheduleNext: (() -> Void)!
                scheduleNext = { [weak self] in
                    guard let self = self else { return }
                    let item = DispatchWorkItem { [weak self] in
                        fn.call(withArguments: [])
                        guard let self = self else { return }
                        MainActor.assumeIsolated {
                            if self.timerTasks[id] != nil {
                                scheduleNext()
                            }
                        }
                    }
                    MainActor.assumeIsolated {
                        self.timerTasks[id] = item
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
                }
                scheduleNext()
                return id
            }
        }

        let clearIntervalBlock: @convention(block) (Double) -> Void = { [weak self] id in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                if let item = self.timerTasks.removeValue(forKey: id) {
                    item.cancel()
                }
            }
        }

        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        context.setObject(setIntervalBlock, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(clearIntervalBlock, forKeyedSubscript: "clearInterval" as NSString)
    }

    private func handleException(_ ctx: JSContext, _ exception: JSValue?) {
        let message = exception?.toString() ?? "Unknown JavaScript exception"
        let stackTrace = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
        logger.error("JS Exception: \(message)\nStack: \(stackTrace)")

        exceptionHandler?(ctx, exception)
    }

    public func evaluateScript(_ script: String, sourceURL: String? = nil) -> JSValue? {
        guard isContextValid else {
            logger.error("Attempted to evaluate script on invalid context")
            return nil
        }

        let url = sourceURL.flatMap { URL(string: $0) }
        lastException = nil
        context.exception = nil
        let result = context.evaluateScript(script, withSourceURL: url)

        if let exception = lastException ?? context.exception {
            handleException(context, exception)
            lastException = nil
            context.exception = nil
            return nil
        }

        return result
    }

    public func evaluateScriptAsync(_ script: String) async -> JSValue? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = self.evaluateScript(script)
                continuation.resume(returning: result)
            }
        }
    }

    public func callFunction(_ name: String, withArguments args: [Any] = []) -> JSValue? {
        guard isContextValid else { return nil }
        guard let fn = context.objectForKeyedSubscript(name) else {
            logger.warning("Function '\(name)' not found in JS context")
            return nil
        }
        return fn.call(withArguments: args)
    }

    public func callFunctionAsync(_ name: String, withArguments args: [Any] = []) async -> JSValue? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = self.callFunction(name, withArguments: args)
                continuation.resume(returning: result)
            }
        }
    }

    public func setGlobalObject(_ object: Any, forKey key: String) {
        guard isContextValid else { return }
        context.setObject(object, forKeyedSubscript: key as NSString)
    }

    public func getGlobalObject(forKey key: String) -> JSValue? {
        guard isContextValid else { return nil }
        return context.objectForKeyedSubscript(key)
    }

    public func injectNativeFunction(
        name: String,
        function: @escaping @convention(block) (JSValue) -> Void
    ) {
        guard isContextValid else { return }
        let jsValue = JSValue(object: function, in: context)
        context.setObject(jsValue, forKeyedSubscript: name as NSString)
    }

    public func injectAsyncFunction(
        name: String,
        function: @escaping @convention(block) (JSValue, JSValue, JSValue) -> Void
    ) {
        guard isContextValid else { return }
        let jsValue = JSValue(object: function, in: context)
        context.setObject(jsValue, forKeyedSubscript: name as NSString)
    }

    public func injectPromiseBasedFunction(
        name: String,
        function: @escaping @convention(block) ([Any], JSValue, JSValue) -> Void
    ) {
        guard isContextValid else { return }
        let jsValue = JSValue(object: function, in: context)
        context.setObject(jsValue, forKeyedSubscript: name as NSString)
    }

    public var globalContext: JSContext {
        return context
    }

    public func invalidate() {
        isContextValid = false
        cleanup()
    }

    private func cleanup() {
        for (_, item) in timerTasks {
            item.cancel()
        }
        timerTasks.removeAll()
        context.exceptionHandler = nil
    }

    public func gc() {
        // JSContext garbage collection is automatic
    }
}

extension SoraJSEngine {
    public func loadModuleScript(_ script: String, moduleName: String) throws {
        // evaluateScript already logged any JS exception via handleException.
        guard evaluateScript(script, sourceURL: moduleName) != nil else {
            throw JSError.scriptLoadFailed("Script evaluation failed for module '\(moduleName)'")
        }
    }

    public func hasFunction(_ name: String) -> Bool {
        guard isContextValid else { return false }
        guard let fn = context.objectForKeyedSubscript(name) else { return false }
        return !fn.isUndefined && !fn.isNull
    }
}

public enum JSError: Error, LocalizedError, Sendable {
    case scriptLoadFailed(String)
    case functionNotFound(String)
    case invalidArguments(String)
    case executionFailed(String)
    case contextInvalidated
    case moduleNotFound
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .scriptLoadFailed(let msg): return "Script load failed: \(msg)"
        case .functionNotFound(let name): return "Function not found: \(name)"
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .executionFailed(let msg): return "Execution failed: \(msg)"
        case .contextInvalidated: return "JavaScript context has been invalidated"
        case .moduleNotFound: return "Module not found or not loaded"
        case .emptyContent: return "No content received"
        }
    }
}