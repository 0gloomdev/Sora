//
//  JSBridge.swift
//  Sora
//
//  Created by Sora Team on 12/09/26.
//

import Foundation
import JavaScriptCore
import os
import SwiftSoup
import WebKit

@MainActor
public final class JSBridge: @unchecked Sendable {
    private let engine: SoraJSEngine
    private let session: URLSession
    private let logger = os.Logger(subsystem: "com.sora.engine", category: "JSBridge")
    /// Retains active `WebFetchMonitor`s until they complete. Without this the
    /// monitor deallocates when `performWebFetch` returns and the fetch silently
    /// never resolves (WKWebView delegate/timer only hold weak references).
    private var webFetchMonitors: [String: WebFetchMonitor] = [:]

    init(engine: SoraJSEngine, session: URLSession = .custom) {
        self.engine = engine
        self.session = session
        injectAll()
    }

    private func injectAll() {
        injectSoraRequest()
        injectSoraFetch()
        injectSoraFetchV2()
        injectBase64()
        injectDOMParser()
        injectSoraCompletion()
        injectScrapingUtils()
        injectDeobfuscator()
        injectSoraWebFetch()
    }

    private func injectSoraRequest() {
        let soraRequest: @convention(block) (String, JSValue?, JSValue, JSValue) -> Void = { [weak self] urlString, optionsValue, resolve, reject in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performSoraRequest(
                    urlString: urlString,
                    optionsValue: optionsValue,
                    resolve: resolve,
                    reject: reject
                )
            }
        }
        engine.setGlobalObject(soraRequest, forKey: "soraRequest")
    }

    private func performSoraRequest(
        urlString: String,
        optionsValue: JSValue?,
        resolve: JSValue,
        reject: JSValue
    ) async {
        guard let url = URL(string: urlString) else {
            reject.call(withArguments: ["Invalid URL: \(urlString)"])
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        var options: RequestOptions = RequestOptions()
        if let optionsDict = optionsValue?.toDictionary() as? [String: Any] {
            options = RequestOptions(from: optionsDict)
        }

        if let method = options.method {
            request.httpMethod = method
        }

        if let headers = options.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let body = options.body, request.httpMethod != "GET" {
            if let jsonData = try? JSONSerialization.data(withJSONObject: body) {
                request.httpBody = jsonData
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                reject.call(withArguments: ["Invalid response"])
                return
            }

            let responseHeaders = httpResponse.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    dict[key] = value
                }
            }

            let encoding = options.encoding ?? .utf8
            let bodyText = String(data: data, encoding: encoding) ?? ""

            let result: [String: Any] = [
                "status": httpResponse.statusCode,
                "headers": responseHeaders,
                "url": httpResponse.url?.absoluteString ?? urlString,
                "body": bodyText,
                "ok": (200...299).contains(httpResponse.statusCode)
            ]

            let jsResult = JSValue(newObjectIn: engine.globalContext)
            jsResult?.setObject(result["status"], forKeyedSubscript: "status" as NSString)
            jsResult?.setObject(result["headers"], forKeyedSubscript: "headers" as NSString)
            jsResult?.setObject(result["url"], forKeyedSubscript: "url" as NSString)
            jsResult?.setObject(result["body"], forKeyedSubscript: "body" as NSString)
            jsResult?.setObject(result["ok"], forKeyedSubscript: "ok" as NSString)

            let textFn: @convention(block) () -> JSValue = { [weak self] in
                guard let self = self else { return JSValue(nullIn: self?.engine.globalContext) }
                return JSValue(object: bodyText, in: self.engine.globalContext) ?? JSValue(nullIn: self.engine.globalContext)
            }
            jsResult?.setObject(textFn, forKeyedSubscript: "text" as NSString)

            let jsonFn: @convention(block) () -> JSValue = { [weak self] in
                guard let self = self else { return JSValue(nullIn: self?.engine.globalContext) }
                do {
                    let json = try JSONSerialization.jsonObject(with: data)
                    return JSValue(object: json, in: self.engine.globalContext) ?? JSValue(nullIn: self.engine.globalContext)
                } catch {
                    return JSValue(nullIn: self.engine.globalContext)
                }
            }
            jsResult?.setObject(jsonFn, forKeyedSubscript: "json" as NSString)

            resolve.call(withArguments: [jsResult as Any])

        } catch {
            logger.error("soraRequest failed: \(error.localizedDescription)")
            reject.call(withArguments: [error.localizedDescription])
        }
    }

    private func injectSoraFetch() {
        let fetch: @convention(block) (String, JSValue?, JSValue, JSValue) -> Void = { [weak self] urlString, headersValue, resolve, reject in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performFetch(
                    urlString: urlString,
                    headersValue: headersValue,
                    resolve: resolve,
                    reject: reject
                )
            }
        }
        engine.setGlobalObject(fetch, forKey: "fetch")
    }

    private func performFetch(
        urlString: String,
        headersValue: JSValue?,
        resolve: JSValue,
        reject: JSValue
    ) async {
        guard let url = URL(string: urlString) else {
            reject.call(withArguments: ["Invalid URL"])
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        if let headersDict = headersValue?.toDictionary() as? [String: String] {
            for (key, value) in headersDict {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        do {
            let (data, _) = try await session.data(for: request)
            if let text = String(data: data, encoding: .utf8) {
                resolve.call(withArguments: [text])
            } else {
                reject.call(withArguments: ["Failed to decode response"])
            }
        } catch {
            reject.call(withArguments: [error.localizedDescription])
        }
    }

    private func injectSoraFetchV2() {
        let fetchV2: @convention(block) (String, JSValue?, JSValue?, JSValue?, JSValue, JSValue) -> Void = { [weak self] urlString, headersValue, methodValue, bodyValue, resolve, reject in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performFetchV2(
                    urlString: urlString,
                    headersValue: headersValue,
                    methodValue: methodValue,
                    bodyValue: bodyValue,
                    resolve: resolve,
                    reject: reject
                )
            }
        }
        engine.setGlobalObject(fetchV2, forKey: "fetchv2")
    }

    private func performFetchV2(
        urlString: String,
        headersValue: JSValue?,
        methodValue: JSValue?,
        bodyValue: JSValue?,
        resolve: JSValue,
        reject: JSValue
    ) async {
        guard let url = URL(string: urlString) else {
            reject.call(withArguments: ["Invalid URL"])
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let method = methodValue?.toString()?.uppercased() ?? "GET"
        request.httpMethod = method

        if let headersDict = headersValue?.toDictionary() as? [String: String] {
            for (key, value) in headersDict {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if method != "GET", let bodyValue = bodyValue {
            if let bodyDict = bodyValue.toDictionary() {
                request.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            } else if let bodyString = bodyValue.toString() {
                request.httpBody = bodyString.data(using: .utf8)
            }
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                reject.call(withArguments: ["Invalid response"])
                return
            }

            let responseHeaders = httpResponse.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    dict[key] = value
                }
            }

            let encoding = String.Encoding.utf8
            let bodyText = String(data: data, encoding: encoding) ?? ""

            let responseObj = JSValue(newObjectIn: engine.globalContext)
            responseObj?.setObject(httpResponse.statusCode, forKeyedSubscript: "status" as NSString)
            responseObj?.setObject(responseHeaders, forKeyedSubscript: "headers" as NSString)
            responseObj?.setObject(httpResponse.url?.absoluteString ?? urlString, forKeyedSubscript: "url" as NSString)
            responseObj?.setObject(bodyText, forKeyedSubscript: "_data" as NSString)

            let textFn: @convention(block) () -> JSValue = { [weak self] in
                guard let self = self else { return JSValue(nullIn: self?.engine.globalContext) }
                return JSValue(object: bodyText, in: self.engine.globalContext) ?? JSValue(nullIn: self.engine.globalContext)
            }
            responseObj?.setObject(textFn, forKeyedSubscript: "text" as NSString)

            let jsonFn: @convention(block) () -> JSValue = { [weak self] in
                guard let self = self else { return JSValue(nullIn: self?.engine.globalContext) }
                do {
                    let json = try JSONSerialization.jsonObject(with: data)
                    return JSValue(object: json, in: self.engine.globalContext) ?? JSValue(nullIn: self.engine.globalContext)
                } catch {
                    return JSValue(nullIn: self.engine.globalContext)
                }
            }
            responseObj?.setObject(jsonFn, forKeyedSubscript: "json" as NSString)

            resolve.call(withArguments: [responseObj as Any])

        } catch {
            reject.call(withArguments: [error.localizedDescription])
        }
    }

    private func injectBase64() {
        let btoa: @convention(block) (String) -> String? = { string in
            string.data(using: .utf8)?.base64EncodedString()
        }
        let atob: @convention(block) (String) -> String? = { base64 in
            Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
        }
        engine.setGlobalObject(btoa, forKey: "btoa")
        engine.setGlobalObject(atob, forKey: "atob")
    }

    private func injectDOMParser() {
        let parseHTML: @convention(block) (String) -> JSValue? = { [weak self] html in
            guard let self = self else { return nil }
            do {
                let parser = try SwiftSoupParser(html: html)
                return parser.toJSValue(in: self.engine.globalContext)
            } catch {
                self.logger.error("SwiftSoup parse error: \(error)")
                return nil
            }
        }

        let querySelector: @convention(block) (String, String) -> JSValue? = { [weak self] html, selector in
            guard let self = self else { return nil }
            do {
                let parser = try SwiftSoupParser(html: html)
                if let element = parser.querySelector(selector) {
                    return SwiftSoupElement(element: element).toJSValue(in: self.engine.globalContext)
                }
                return JSValue(nullIn: self.engine.globalContext)
            } catch {
                self.logger.error("SwiftSoup querySelector error: \(error)")
                return JSValue(nullIn: self.engine.globalContext)
            }
        }

        let querySelectorAll: @convention(block) (String, String) -> JSValue? = { [weak self] html, selector in
            guard let self = self else { return nil }
            do {
                let parser = try SwiftSoupParser(html: html)
                let elements = parser.querySelectorAll(selector)
                let array: [Any] = elements.array().compactMap { SwiftSoupElement(element: $0).toJSValue(in: self.engine.globalContext) }
                return JSValue(object: array, in: self.engine.globalContext)
            } catch {
                self.logger.error("SwiftSoup querySelectorAll error: \(error)")
                return JSValue(nullIn: self.engine.globalContext)
            }
        }

        engine.setGlobalObject(parseHTML, forKey: "soraParseHTML")
        engine.setGlobalObject(querySelector, forKey: "soraQuerySelector")
        engine.setGlobalObject(querySelectorAll, forKey: "soraQuerySelectorAll")
    }

    private func injectSoraCompletion() {
        let soraCompletion: @convention(block) (JSValue, JSValue?) -> Void = { result, error in
            // This is a placeholder - actual completion handling is done by execution modes
            // Modules should call soraCompletion(result) or soraCompletion(null, error)
        }
        engine.setGlobalObject(soraCompletion, forKey: "soraCompletion")
    }

    private func injectScrapingUtils() {
        let utils = #"""
        function soraGetElementsByTag(html, tag) {
            const regex = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\/${tag}>`, 'gi');
            let result = [];
            let match;
            while ((match = regex.exec(html)) !== null) {
                result.push(match[1]);
            }
            return result;
        }

        function soraGetAttribute(html, tag, attr) {
            const regex = new RegExp(`<${tag}[^>]*${attr}=["']?([^"' >]+)["']?[^>]*>`, 'i');
            const match = regex.exec(html);
            return match ? match[1] : null;
        }

        function soraGetInnerText(html) {
            return html.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
        }

        function soraExtractBetween(str, start, end) {
            const s = str.indexOf(start);
            if (s === -1) return '';
            const e = str.indexOf(end, s + start.length);
            if (e === -1) return '';
            return str.substring(s + start.length, e);
        }

        function soraStripHtml(html) {
            return html.replace(/<[^>]+>/g, '');
        }

        function soraNormalizeWhitespace(str) {
            return str.replace(/\s+/g, ' ').trim();
        }

        function soraUrlEncode(str) {
            return encodeURIComponent(str);
        }

        function soraUrlDecode(str) {
            try { return decodeURIComponent(str); } catch (e) { return str; }
        }

        function soraHtmlEntityDecode(str) {
            const entities = { quot: '"', apos: "'", amp: '&', lt: '<', gt: '>' };
            return str.replace(/&([a-zA-Z]+);/g, function(_, entity) {
                return entities[entity] || _;
            });
        }
        """#
        engine.evaluateScript(utils)
    }

    private func injectDeobfuscator() {
        let deobfuscator = #"""
        function soraUnpack(source) {
            let { payload, symtab, radix, count } = soraFilterArgs(source);
            if (count != symtab.length) {
                throw Error("Malformed p.a.c.k.e.r. symtab.");
            }
            let unbase;
            try {
                unbase = new soraUnbaser(radix);
            } catch (e) {
                throw Error("Unknown p.a.c.k.e.r. encoding.");
            }
            function lookup(match) {
                const word = match;
                let word2;
                if (radix == 1) {
                    word2 = symtab[parseInt(word)];
                } else {
                    word2 = symtab[unbase.unbase(word)];
                }
                return word2 || word;
            }
            source = payload.replace(/\b\w+\b/g, lookup);
            return soraReplaceStrings(source);

            function soraFilterArgs(source) {
                const juicers = [
                    /}\('(.*)', *(\d+|\[\]), *(\d+), *'(.*)'\.split\('\|'\), *(\d+), *(.*)\)\)/,
                    /}\('(.*)', *(\d+|\[\]), *(\d+), *'(.*)'\.split\('\|'\)/,
                ];
                for (const juicer of juicers) {
                    const args = juicer.exec(source);
                    if (args) {
                        let a = args;
                        if (a[2] == "[]") {}
                        try {
                            return {
                                payload: a[1],
                                symtab: a[4].split("|"),
                                radix: parseInt(a[2]),
                                count: parseInt(a[3]),
                            };
                        } catch (ValueError) {
                            throw Error("Corrupted p.a.c.k.e.r. data.");
                        }
                    }
                }
                throw Error("Could not make sense of p.a.c.k.e.r data");
            }

            function soraReplaceStrings(source) {
                return source;
            }
        }

        class soraUnbaser {
            constructor(base) {
                this.ALPHABET = {
                    62: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
                    95: "' !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~'",
                };
                this.dictionary = {};
                this.base = base;
                if (36 < base && base < 62) {
                    this.ALPHABET[base] = this.ALPHABET[base] || this.ALPHABET[62].substr(0, base);
                }
                if (2 <= base && base <= 36) {
                    this.unbase = (value) => parseInt(value, base);
                } else {
                    try {
                        [...this.ALPHABET[base]].forEach((cipher, index) => {
                            this.dictionary[cipher] = index;
                        });
                    } catch (er) {
                        throw Error("Unsupported base encoding.");
                    }
                    this.unbase = this._dictunbaser;
                }
            }
            _dictunbaser(value) {
                let ret = 0;
                [...value].reverse().forEach((cipher, index) => {
                    ret = ret + ((Math.pow(this.base, index)) * this.dictionary[cipher]);
                });
                return ret;
            }
        }

        function soraDetect(source) {
            return source.replace(" ", "").startsWith("eval(function(p,a,c,k,e,");
        }
        """#
        engine.evaluateScript(deobfuscator)
    }

    private func injectSoraWebFetch() {
        let webFetch: @convention(block) (String, JSValue?, JSValue, JSValue) -> Void = { [weak self] urlString, optionsValue, resolve, reject in
            guard let self = self else { return }
            Task { @MainActor in
                await self.performWebFetch(
                    urlString: urlString,
                    optionsValue: optionsValue,
                    resolve: resolve,
                    reject: reject
                )
            }
        }
        engine.setGlobalObject(webFetch, forKey: "soraWebFetch")
    }

    private func performWebFetch(
        urlString: String,
        optionsValue: JSValue?,
        resolve: JSValue,
        reject: JSValue
    ) async {
        guard let url = URL(string: urlString) else {
            reject.call(withArguments: ["Invalid URL: \(urlString)"])
            return
        }

        var options: WebFetchOptions = WebFetchOptions()
        if let optionsDict = optionsValue?.toDictionary() as? [String: Any] {
            options = WebFetchOptions(from: optionsDict)
        }

        let monitorId = UUID().uuidString
        let monitor = WebFetchMonitor()
        webFetchMonitors[monitorId] = monitor
        monitor.startMonitoring(
            url: url,
            options: options
        ) { [weak self] result in
            self?.webFetchMonitors.removeValue(forKey: monitorId)
            guard self != nil else { return }
            DispatchQueue.main.async {
                if !resolve.isUndefined {
                    let jsResult = JSValue(newObjectIn: self?.engine.globalContext ?? JSContext())
                    jsResult?.setObject(result["success"] as? Bool ?? false, forKeyedSubscript: "success" as NSString)
                    jsResult?.setObject(result["html"] as? String ?? "", forKeyedSubscript: "html" as NSString)
                    jsResult?.setObject(result["url"] as? String ?? urlString, forKeyedSubscript: "url" as NSString)
                    jsResult?.setObject(result["requests"] as? [String] ?? [], forKeyedSubscript: "requests" as NSString)
                    if let error = result["error"] as? String {
                        jsResult?.setObject(error, forKeyedSubscript: "error" as NSString)
                    }
                    resolve.call(withArguments: [jsResult as Any])
                }
            }
        }
    }

    private struct RequestOptions {
        var method: String? = nil
        var headers: [String: String]? = nil
        var body: [String: Any]? = nil
        var encoding: String.Encoding? = nil
        var timeout: TimeInterval? = nil

        init() {}

        init(from dict: [String: Any]) {
            self.method = dict["method"] as? String
            self.headers = dict["headers"] as? [String: String]
            if let body = dict["body"] as? [String: Any] {
                self.body = body
            }
            if let encodingStr = dict["encoding"] as? String {
                self.encoding = Self.encodingFromString(encodingStr)
            }
            if let timeout = dict["timeout"] as? TimeInterval {
                self.timeout = timeout
            }
        }

        private static func encodingFromString(_ string: String) -> String.Encoding {
            switch string.lowercased() {
            case "utf-8", "utf8": return .utf8
            case "windows-1251", "cp1251": return .windowsCP1251
            case "windows-1252", "cp1252": return .windowsCP1252
            case "iso-8859-1", "latin1": return .isoLatin1
            case "ascii": return .ascii
            case "utf-16", "utf16": return .utf16
            default: return .utf8
            }
        }
    }

    private struct WebFetchOptions {
        var timeoutSeconds: Int = 10
        var headers: [String: String] = [:]
        var cutoff: String? = nil
        var returnHTML: Bool = true
        var returnCookies: Bool = true
        var clickSelectors: [String] = []
        var waitForSelectors: [String] = []
        var maxWaitTime: Int = 5
        var htmlContent: String? = nil
        var userAgent: String? = nil

        init() {}

        init(from dict: [String: Any]) {
            self.timeoutSeconds = dict["timeoutSeconds"] as? Int ?? 10
            self.headers = dict["headers"] as? [String: String] ?? [:]
            self.cutoff = dict["cutoff"] as? String
            self.returnHTML = dict["returnHTML"] as? Bool ?? true
            self.returnCookies = dict["returnCookies"] as? Bool ?? true
            self.clickSelectors = dict["clickSelectors"] as? [String] ?? []
            self.waitForSelectors = dict["waitForSelectors"] as? [String] ?? []
            self.maxWaitTime = dict["maxWaitTime"] as? Int ?? 5
            self.htmlContent = dict["htmlContent"] as? String
            self.userAgent = dict["userAgent"] as? String
        }
    }

    @MainActor
    private final class WebFetchMonitor: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var webView: WKWebView?
        private var completionHandler: (([String: Any]) -> Void)?
        private var timer: Timer?
        private var options: WebFetchOptions?
        private var networkRequests: [String] = []
        private var cookies: [String: String] = [:]
        private var htmlContent: String? = nil
        private var htmlCaptured = false
        private var cookiesCaptured = false

        func startMonitoring(url: URL, options: WebFetchOptions, completion: @escaping ([String: Any]) -> Void) {
            self.options = options
            self.completionHandler = completion
            self.networkRequests.removeAll()
            self.cookies.removeAll()
            self.htmlContent = nil
            self.htmlCaptured = false
            self.cookiesCaptured = false

            setupWebView()

            if let htmlContent = options.htmlContent, !htmlContent.isEmpty {
                loadHTMLContent(htmlContent)
            } else {
                loadURL(url: url, headers: options.headers)
            }

            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(options.timeoutSeconds), repeats: false) { [weak self] _ in
                if options.returnHTML || options.returnCookies {
                    self?.captureDataThenComplete()
                } else {
                    self?.stopMonitoring(success: true)
                }
            }
        }

        private func setupWebView() {
            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []

            let jsCode = #"""
            (function() {
                Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
                Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
                Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
                delete window.navigator.__proto__.webdriver;
                
                window.chrome = { runtime: {} };
                Object.defineProperty(navigator, 'permissions', { get: () => undefined });
                
                const originalFetch = window.fetch;
                const originalXHROpen = XMLHttpRequest.prototype.open;
                const originalXHRSend = XMLHttpRequest.prototype.send;
                
                window.fetch = function() {
                    const url = arguments[0];
                    const options = arguments[1] || {};
                    
                    try {
                        const fullUrl = new URL(url, window.location.href).href;
                        window.webkit.messageHandlers.networkLogger.postMessage({
                            type: 'fetch',
                            url: fullUrl
                        });
                    } catch(e) {
                        window.webkit.messageHandlers.networkLogger.postMessage({
                            type: 'fetch',
                            url: url.toString()
                        });
                    }
                    return originalFetch.apply(this, arguments);
                };
                
                XMLHttpRequest.prototype.open = function() {
                    const method = arguments[0];
                    const url = arguments[1];
                    
                    try {
                        this._url = new URL(url, window.location.href).href;
                    } catch(e) {
                        this._url = url;
                    }
                    
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: 'xhr-open',
                        url: this._url
                    });
                    
                    const self = this;
                    const originalOnReadyStateChange = this.onreadystatechange;
                    
                    this.onreadystatechange = function() {
                        if (this.readyState === 4) {
                            if (this.responseURL) {
                                window.webkit.messageHandlers.networkLogger.postMessage({
                                    type: 'xhr-response',
                                    url: this.responseURL
                                });
                            }
                            
                            try {
                                const responseText = this.responseText;
                                if (responseText) {
                                    const urlRegex = /(https?:\/\/[^\s"'<>]+\.(m3u8|ts|mp4|webm|mkv))/gi;
                                    const matches = responseText.match(urlRegex);
                                    if (matches) {
                                        matches.forEach(function(match) {
                                            window.webkit.messageHandlers.networkLogger.postMessage({
                                                type: 'response-content',
                                                url: match
                                            });
                                        });
                                    }
                                }
                            } catch(e) {
                            }
                        }
                        
                        if (originalOnReadyStateChange) {
                            originalOnReadyStateChange.apply(this, arguments);
                        }
                    };
                    
                    return originalXHROpen.apply(this, arguments);
                };
                
                XMLHttpRequest.prototype.send = function() {
                    if (this._url) {
                        window.webkit.messageHandlers.networkLogger.postMessage({
                            type: 'xhr-send',
                            url: this._url
                        });
                    }
                    return originalXHRSend.apply(this, arguments);
                };
                
                const originalWebSocket = window.WebSocket;
                window.WebSocket = function(url, protocols) {
                    window.webkit.messageHandlers.networkLogger.postMessage({
                        type: 'websocket',
                        url: url
                    });
                    return new originalWebSocket(url, protocols);
                };
                
                const hookUrlProperties = function(obj, properties) {
                    properties.forEach(function(prop) {
                        if (obj && obj.prototype) {
                            const descriptor = Object.getOwnPropertyDescriptor(obj.prototype, prop) || {};
                            const originalSetter = descriptor.set;
                            
                            if (originalSetter) {
                                Object.defineProperty(obj.prototype, prop, {
                                    set: function(value) {
                                        if (typeof value === 'string' && (value.includes('http') || value.includes('.m3u8') || value.includes('.ts'))) {
                                            window.webkit.messageHandlers.networkLogger.postMessage({
                                                type: 'property-set',
                                                url: value
                                            });
                                        }
                                        return originalSetter.call(this, value);
                                    },
                                    get: descriptor.get,
                                    configurable: true
                                });
                            }
                        }
                    });
                };
                
                hookUrlProperties(HTMLVideoElement, ['src']);
                hookUrlProperties(HTMLSourceElement, ['src']);
                hookUrlProperties(HTMLScriptElement, ['src']);
                hookUrlProperties(HTMLImageElement, ['src']);
                
                let jwHookAttempts = 0;
                const aggressiveJWHook = function() {
                    jwHookAttempts++;
                    
                    if (window.jwplayer) {
                        const originalJWPlayer = window.jwplayer;
                        window.jwplayer = function(id) {
                            const player = originalJWPlayer.apply(this, arguments);
                            
                            if (player && player.setup) {
                                const originalSetup = player.setup;
                                player.setup = function(config) {
                                    const extractUrls = function(obj, path = '') {
                                        if (!obj) return;
                                        
                                        if (typeof obj === 'string' && (obj.includes('http') || obj.includes('.m3u8') || obj.includes('.ts'))) {
                                            window.webkit.messageHandlers.networkLogger.postMessage({
                                                type: 'jwplayer-config',
                                                url: obj
                                            });
                                        } else if (typeof obj === 'object' && obj !== null) {
                                            Object.keys(obj).forEach(function(key) {
                                                extractUrls(obj[key], path + '.' + key);
                                            });
                                        }
                                    };
                                    
                                    extractUrls(config);
                                    return originalSetup.call(this, config);
                                };
                            };
                            
                            Object.keys(originalJWPlayer).forEach(function(key) {
                                window.jwplayer[key] = originalJWPlayer[key];
                            });
                        }
                    }
                    
                    if (jwHookAttempts < 20) {
                        setTimeout(aggressiveJWHook, 200);
                    }
                };
                
                aggressiveJWHook();
                
                window.waitForElementAndClick = function(waitSelectors, clickSelectors, maxWaitTime) {
                    return new Promise(function(resolve) {
                        const results = {
                            waitResults: {},
                            clickResults: []
                        };
                        
                        waitSelectors.forEach(function(selector) {
                            results.waitResults[selector] = false;
                        });
                        
                        const startTime = Date.now();
                        const checkInterval = 100; 
                        
                        const checkAndClick = function() {
                            const elapsed = (Date.now() - startTime) / 1000;
                            
                            let allFound = waitSelectors.length === 0; 
                            
                            waitSelectors.forEach(function(selector) {
                                const element = document.querySelector(selector);
                                if (element && element.offsetParent !== null) { 
                                    results.waitResults[selector] = true;
                                }
                            });
                            
                            allFound = waitSelectors.every(function(selector) {
                                return results.waitResults[selector];
                            });
                            
                            if (allFound || elapsed >= maxWaitTime) {
                                clickSelectors.forEach(function(selector) {
                                    try {
                                        const elements = document.querySelectorAll(selector);
                                        let clicked = false;
                                        
                                        elements.forEach(function(element) {
                                            if (element && element.offsetParent !== null) {
                                                try {
                                                    element.click();
                                                    clicked = true;
                                                } catch(e1) {
                                                    try {
                                                        const event = new MouseEvent('click', {
                                                            view: window,
                                                            bubbles: true,
                                                            cancelable: true
                                                        });
                                                        element.dispatchEvent(event);
                                                        clicked = true;
                                                    } catch(e2) {
                                                    }
                                                }
                                            }
                                        });
                                        
                                        results.clickResults.push({
                                            selector: selector,
                                            success: clicked,
                                            elementsFound: elements.length
                                        });
                                    } catch(e) {
                                        results.clickResults.push({
                                            selector: selector,
                                            success: false,
                                            error: e.message
                                        });
                                    }
                                });
                                
                                window.webkit.messageHandlers.networkLogger.postMessage({
                                    type: 'click-results',
                                    results: results
                                });
                                
                                resolve(results);
                            } else if (elapsed < maxWaitTime) {
                                setTimeout(checkAndClick, checkInterval);
                            }
                        };
                        
                        checkAndClick();
                    });
                };
                
                const nuclearScan = function() {
                    Object.keys(window).forEach(function(key) {
                        try {
                            const value = window[key];
                            if (typeof value === 'string' && (value.includes('.m3u8') || value.includes('.ts') || (value.includes('http') && value.includes('.')))) {
                                window.webkit.messageHandlers.networkLogger.postMessage({
                                    type: 'global-variable',
                                    url: value
                                });
                            }
                        } catch(e) {
                        }
                    });
                    
                    document.querySelectorAll('script').forEach(function(script) {
                        if (script.textContent) {
                            const urlRegex = /(https?:\/\/[^\s"'<>]+\.(m3u8|ts|mp4))/gi;
                            const matches = script.textContent.match(urlRegex);
                            if (matches) {
                                matches.forEach(function(match) {
                                    window.webkit.messageHandlers.networkLogger.postMessage({
                                        type: 'script-content',
                                        url: match
                                    });
                                });
                            }
                        }
                    });
                    
                    const clickableSelectors = [
                        'button', '.play', '.play-button', '[data-play]', '.video-play',
                        '.jwplayer', '.player', '[id*="player"]', '[class*="play"]',
                        'div[onclick]', 'span[onclick]', 'a[onclick]'
                    ];
                    
                    clickableSelectors.forEach(function(selector) {
                        document.querySelectorAll(selector).forEach(function(el) {
                            try {
                                el.click();
                            } catch(e) {
                            }
                        });
                    });
                };
                
                setTimeout(nuclearScan, 500);
                setTimeout(nuclearScan, 1500);
                setTimeout(nuclearScan, 3000);
                
                window.captureCookies = function() {
                    const cookies = {};
                    document.cookie.split(';').forEach(function(cookie) {
                        const parts = cookie.trim().split('=');
                        if (parts.length === 2) {
                            cookies[parts[0]] = decodeURIComponent(parts[1]);
                        }
                    });
                    
                    if (Object.keys(cookies).length > 0) {
                        window.webkit.messageHandlers.networkLogger.postMessage({
                            type: 'cookies',
                            cookies: cookies
                        });
                    }
                    
                    return cookies;
                };
            })();
            """#

            let userScript = WKUserScript(source: jsCode, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(userScript)
            config.userContentController.add(self, name: "networkLogger")

            webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
            webView?.navigationDelegate = self

            let ua = options?.userAgent ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"
            webView?.customUserAgent = ua
        }

        private func loadHTMLContent(_ htmlContent: String) {
            guard let webView = webView else { return }
            networkRequests.append("data:text/html;charset=utf-8,<html_content>")
            webView.loadHTMLString(htmlContent, baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.simulateUserInteraction()
            }
        }

        private func loadURL(url: URL, headers: [String: String] = [:]) {
            guard let webView = webView else { return }
            networkRequests.append(url.absoluteString)
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("upgrade-insecure-requests", forHTTPHeaderField: "Upgrade-Insecure-Requests")
            request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
            request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let randomReferers = [
                "https://www.google.com/",
                "https://www.youtube.com/",
                "https://twitter.com/",
                "https://www.reddit.com/",
                "https://www.facebook.com/"
            ]
            let randomReferer = randomReferers.randomElement() ?? "https://www.google.com/"
            if request.value(forHTTPHeaderField: "Referer") == nil {
                request.setValue(randomReferer, forHTTPHeaderField: "Referer")
            }
            webView.load(request)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.simulateUserInteraction()
            }
        }

        private func simulateUserInteraction() {
            guard let webView = webView else { return }
            guard let options = options else { return }

            let jsInteraction = #"""
            setTimeout(function() {
                const playButtons = document.querySelectorAll('button, div, span, a').filter(function(el) {
                    const text = el.textContent || el.innerText || '';
                    const classes = el.className || '';
                    return text.toLowerCase().includes('play') || 
                           classes.toLowerCase().includes('play') ||
                           el.getAttribute('aria-label')?.toLowerCase().includes('play');
                });
                playButtons.forEach(function(btn, index) {
                    setTimeout(function() {
                        btn.click();
                    }, index * 200);
                });
                window.scrollTo(0, document.body.scrollHeight / 2);
                setTimeout(function() {
                    window.scrollTo(0, 0);
                }, 500);
                document.querySelectorAll('video').forEach(function(video) {
                    if (video.play && typeof video.play === 'function') {
                        video.play().catch(function(e) {
                        });
                    }
                });
                if (window.jwplayer) {
                    try {
                        const players = window.jwplayer().getInstances?.() || [];
                        players.forEach(function(player) {
                            if (player.play) {
                                player.play();
                            }
                        });
                    } catch(e) {}
                }
                if (window.videojs) {
                    try {
                        window.videojs.getAllPlayers?.().forEach(function(player) {
                            if (player.play) {
                                player.play();
                            }
                        });
                    } catch(e) {}
                }
            }, 1000);
            """#
            webView.evaluateJavaScript(jsInteraction, completionHandler: nil)

            if !options.clickSelectors.isEmpty || !options.waitForSelectors.isEmpty {
                let clickJs = """
                window.waitForElementAndClick(\(try! JSONEncoder().encode(options.waitForSelectors)), \(try! JSONEncoder().encode(options.clickSelectors)), \(options.maxWaitTime))
                """
                webView.evaluateJavaScript(clickJs, completionHandler: nil)
            }
        }

        private func captureDataThenComplete() {
            guard let webView = webView, let options = options else {
                stopMonitoring(success: false)
                return
            }

            let shouldCaptureHTML = options.returnHTML
            let shouldCaptureCookies = options.returnCookies

            var completedTasks = 0
            let totalTasks = (shouldCaptureHTML ? 1 : 0) + (shouldCaptureCookies ? 1 : 0)

            if totalTasks == 0 {
                stopMonitoring(success: true)
                return
            }

            let checkCompletion = { [weak self] in
                completedTasks += 1
                if completedTasks >= totalTasks {
                    self?.stopMonitoring(success: true)
                }
            }

            if shouldCaptureHTML {
                webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
                    DispatchQueue.main.async {
                        if let html = result as? String, error == nil {
                            self?.htmlContent = html
                            self?.htmlCaptured = true
                        }
                        checkCompletion()
                    }
                }
            }

            if shouldCaptureCookies {
                captureCookies {
                    DispatchQueue.main.async {
                        checkCompletion()
                    }
                }
            }
        }

        private func captureCookies(completion: @escaping () -> Void) {
            guard let webView = webView else {
                completion()
                return
            }

            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore

            cookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async {
                    var cookieDict: [String: String] = [:]
                    for cookie in cookies {
                        cookieDict[cookie.name] = cookie.value
                    }

                    self?.cookies = cookieDict
                    self?.cookiesCaptured = !cookieDict.isEmpty

                    completion()
                }
            }
        }

        private func stopMonitoring(success: Bool) {
            timer?.invalidate()
            timer = nil

            webView?.stopLoading()
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "networkLogger")

            let originalUrl = webView?.url?.absoluteString ?? ""

            var result: [String: Any] = [
                "originalUrl": originalUrl,
                "requests": networkRequests,
                "success": success,
                "htmlCaptured": htmlCaptured,
                "cookiesCaptured": cookiesCaptured
            ]

            if htmlCaptured, let html = htmlContent {
                result["html"] = html
            }

            if cookiesCaptured, !cookies.isEmpty {
                result["cookies"] = cookies
            }

            webView = nil

            completionHandler?(result)
            completionHandler = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                addRequest(url.absoluteString)
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "networkLogger" {
                if let messageBody = message.body as? [String: Any],
                   let url = messageBody["url"] as? String {
                    addRequest(url)
                }
            }
        }

        private func addRequest(_ urlString: String) {
            DispatchQueue.main.async {
                if !self.networkRequests.contains(urlString) {
                    self.networkRequests.append(urlString)
                }
            }
        }
    }

    @MainActor
    private final class SwiftSoupParser {
        private let document: Document

        init(html: String) throws {
            self.document = try SwiftSoup.parse(html)
        }

        func querySelector(_ selector: String) -> Element? {
            try? document.select(selector).first()
        }

        func querySelectorAll(_ selector: String) -> Elements {
            (try? document.select(selector)) ?? Elements()
        }

        func toJSValue(in context: JSContext) -> JSValue? {
            let obj = JSValue(newObjectIn: context)
            obj?.setObject((try? document.html()) ?? "", forKeyedSubscript: "html" as NSString)
            obj?.setObject(querySelector, forKeyedSubscript: "querySelector" as NSString)
            obj?.setObject(querySelectorAll, forKeyedSubscript: "querySelectorAll" as NSString)
            obj?.setObject(getTitle, forKeyedSubscript: "title" as NSString)
            obj?.setObject(getBodyHtml, forKeyedSubscript: "bodyHtml" as NSString)
            return obj
        }

        func getTitle() -> String {
            (try? document.title()) ?? ""
        }

        func getBodyHtml() -> String {
            (try? document.body()?.html()) ?? ""
        }
    }

    @MainActor
    private final class SwiftSoupElement {
        private let element: Element

        init(element: Element) {
            self.element = element
        }

        func toJSValue(in context: JSContext) -> JSValue? {
            let obj = JSValue(newObjectIn: context)
            obj?.setObject((try? element.html()) ?? "", forKeyedSubscript: "outerHTML" as NSString)
            obj?.setObject((try? element.text()) ?? "", forKeyedSubscript: "innerText" as NSString)
            obj?.setObject(getAttribute, forKeyedSubscript: "getAttribute" as NSString)
            obj?.setObject(getAttr, forKeyedSubscript: "getAttr" as NSString)
            obj?.setObject(element.tagName(), forKeyedSubscript: "tagName" as NSString)
            let attrs: [String: String] = (element.getAttributes()?.asList() ?? []).reduce(into: [:]) { dict, attr in
                dict[attr.getKey()] = attr.getValue()
            }
            obj?.setObject(attrs, forKeyedSubscript: "attributes" as NSString)
            return obj
        }

        func getAttribute(_ name: String) -> String? {
            try? element.attr(name)
        }

        func getAttr(_ name: String) -> String {
            (try? element.attr(name)) ?? ""
        }
    }
}