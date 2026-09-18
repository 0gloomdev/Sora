//
//  NovelFallback.swift
//  Sora
//
//  Native fallback for novel chapter extraction when the module's
//  JavaScript `extractText` fails. Fetches the chapter HTML directly
//  and keeps the most readable section, stripping chrome elements.
//

import Foundation

enum NovelFallbackError: Error, LocalizedError, Sendable {
    case invalidURL
    case requestFailed(String)
    case badStatus(Int)
    case undecodable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid chapter URL"
        case .requestFailed(let message):
            return "Direct fetch failed: \(message)"
        case .badStatus(let code):
            return "Direct fetch failed with status code: \(code)"
        case .undecodable:
            return "Failed to decode chapter response"
        }
    }
}

struct NovelContentFallback {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Mobile/15E148 Safari/604.1"

    static func fetchDirectContent(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw NovelFallbackError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")

        Logger.shared.log("Attempting direct fetch from: \(url.absoluteString)", type: "Debug")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Logger.shared.log("Direct fetch error: \(error.localizedDescription)", type: "Error")
            throw NovelFallbackError.requestFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Logger.shared.log("Direct fetch failed with status code: \(code)", type: "Error")
            throw NovelFallbackError.badStatus(code)
        }

        guard let htmlString = String(data: data, encoding: .utf8) else {
            Logger.shared.log("Failed to decode response data", type: "Error")
            throw NovelFallbackError.undecodable
        }

        let content = cleanHTMLContent(extractReadableSection(from: htmlString))
        Logger.shared.log("Direct fetch successful, content length: \(content.count)", type: "Debug")
        return content
    }

    private static func extractReadableSection(from htmlString: String) -> String {
        let candidates: [(open: String, close: String, label: String)] = [
            ("<article", "</article>", "article tag"),
            ("<div class=\"chapter-content\"", "</div>", "chapter-content div"),
            ("<div class=\"content\"", "</div>", "content div"),
            ("<div id=\"chapter-content\"", "</div>", "chapter-content id div"),
            ("<div class=\"chapter\"", "</div>", "chapter div"),
            ("<main", "</main>", "main tag"),
            ("<body", "</body>", "body tag"),
        ]

        for candidate in candidates {
            guard let contentRange = htmlString.range(of: candidate.open, options: .caseInsensitive) else {
                continue
            }
            let closeRange = htmlString.range(
                of: candidate.close,
                options: .caseInsensitive,
                range: contentRange.upperBound..<htmlString.endIndex
            ) ?? htmlString.range(of: candidate.close, options: .caseInsensitive)
            if let endRange = closeRange {
                Logger.shared.log("Extracted content from \(candidate.label)", type: "Debug")
                return String(htmlString[contentRange.lowerBound..<endRange.upperBound])
            }
        }

        Logger.shared.log("Using full HTML content", type: "Debug")
        return htmlString
    }

    private static func cleanHTMLContent(_ content: String) -> String {
        var cleaned = content

        for pattern in [
            "<script[^>]*>.*?</script>",
            "<style[^>]*>.*?</style>",
            "<nav[^>]*>.*?</nav>",
            "<header[^>]*>.*?</header>",
            "<footer[^>]*>.*?</footer>",
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        let unwantedClasses = ["advertisement", "ads", "sidebar", "menu", "navigation", "nav", "header", "footer", "comments", "comment"]
        for className in unwantedClasses {
            cleaned = cleaned.replacingOccurrences(
                of: "<div[^>]*class=\"[^\"]*\(className)[^\"]*\"[^>]*>.*?</div>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
