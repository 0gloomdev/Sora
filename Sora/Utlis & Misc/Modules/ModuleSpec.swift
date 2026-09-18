//
//  ModuleSpec.swift
//  Sora
//
//  Created by Sora Team on 12/09/26.
//

import Foundation

public enum ExecutionMode: String, Codable, CaseIterable, Sendable {
    case normal = "normal"
    case async = "async"
    case streamAsync = "streamAsync"
    case softSubs = "softSubs"

    public var requiresAsync: Bool {
        switch self {
        case .normal: return false
        case .async, .streamAsync, .softSubs: return true
        }
    }

    public var supportsStreaming: Bool {
        switch self {
        case .streamAsync, .softSubs: return true
        case .normal, .async: return false
        }
    }

    public var supportsSubtitles: Bool {
        switch self {
        case .softSubs: return true
        case .normal, .async, .streamAsync: return false
        }
    }
}

public enum StreamType: String, Codable, CaseIterable, Sendable {
    case hls = "HLS"
    case mp4 = "MP4"
    case dash = "DASH"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = StreamType(rawValue: raw.uppercased()) ?? .unknown
    }
}

public enum Quality: String, Codable, CaseIterable, Sendable {
    case p360 = "360p"
    case p480 = "480p"
    case p720 = "720p"
    case p1080 = "1080p"
    case p4k = "4K"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Quality(rawValue: raw) ?? .unknown
    }
}

public struct Author: Codable, Hashable, Sendable {
    public let name: String
    public let icon: String

    public init(name: String, icon: String) {
        self.name = name
        self.icon = icon
    }
}

public struct ModuleMetadata: Codable, Hashable, Sendable {
    public let sourceName: String
    public let author: Author
    public let iconUrl: String
    public let version: String
    public let language: String
    public let baseUrl: String
    public let streamType: StreamType
    public let quality: Quality
    public let searchBaseUrl: String
    public let scriptUrl: String
    public let asyncJS: Bool?
    public let streamAsyncJS: Bool?
    public let softsub: Bool?
    public let multiStream: Bool?
    public let multiSubs: Bool?
    public let type: ModuleType?
    public let novel: Bool?

    public var executionMode: ExecutionMode {
        if softsub == true { return .softSubs }
        if streamAsyncJS == true { return .streamAsync }
        if asyncJS == true { return .async }
        return .normal
    }

    public init(
        sourceName: String,
        author: Author,
        iconUrl: String,
        version: String,
        language: String,
        baseUrl: String,
        streamType: StreamType,
        quality: Quality,
        searchBaseUrl: String,
        scriptUrl: String,
        asyncJS: Bool? = nil,
        streamAsyncJS: Bool? = nil,
        softsub: Bool? = nil,
        multiStream: Bool? = nil,
        multiSubs: Bool? = nil,
        type: ModuleType? = nil,
        novel: Bool? = nil
    ) {
        self.sourceName = sourceName
        self.author = author
        self.iconUrl = iconUrl
        self.version = version
        self.language = language
        self.baseUrl = baseUrl
        self.streamType = streamType
        self.quality = quality
        self.searchBaseUrl = searchBaseUrl
        self.scriptUrl = scriptUrl
        self.asyncJS = asyncJS
        self.streamAsyncJS = streamAsyncJS
        self.softsub = softsub
        self.multiStream = multiStream
        self.multiSubs = multiSubs
        self.type = type
        self.novel = novel
    }

    private enum CodingKeys: String, CodingKey {
        case sourceName
        case author
        case iconUrl
        case version
        case language
        case baseUrl
        case streamType
        case quality
        case searchBaseUrl
        case scriptUrl
        case asyncJS
        case streamAsyncJS
        case softsub
        case multiStream
        case multiSubs
        case type
        case novel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sourceName = try container.decode(String.self, forKey: .sourceName)
        self.author = try container.decode(Author.self, forKey: .author)
        self.iconUrl = try container.decode(String.self, forKey: .iconUrl)
        if let versionString = try? container.decode(String.self, forKey: .version) {
            self.version = versionString
        } else if let versionInt = try? container.decode(Int.self, forKey: .version) {
            self.version = String(versionInt)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.version],
                    debugDescription: "Expected version to be a String or Int"
                )
            )
        }
        self.language = try container.decode(String.self, forKey: .language)
        self.baseUrl = try container.decode(String.self, forKey: .baseUrl)
        self.streamType = try container.decode(StreamType.self, forKey: .streamType)
        self.quality = try container.decode(Quality.self, forKey: .quality)
        self.searchBaseUrl = try container.decode(String.self, forKey: .searchBaseUrl)
        self.scriptUrl = try container.decode(String.self, forKey: .scriptUrl)
        self.asyncJS = try container.decodeIfPresent(Bool.self, forKey: .asyncJS)
        self.streamAsyncJS = try container.decodeIfPresent(Bool.self, forKey: .streamAsyncJS)
        self.softsub = try container.decodeIfPresent(Bool.self, forKey: .softsub)
        self.multiStream = try container.decodeIfPresent(Bool.self, forKey: .multiStream)
        self.multiSubs = try container.decodeIfPresent(Bool.self, forKey: .multiSubs)
        self.type = try container.decodeIfPresent(ModuleType.self, forKey: .type)
        self.novel = try container.decodeIfPresent(Bool.self, forKey: .novel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(author, forKey: .author)
        try container.encode(iconUrl, forKey: .iconUrl)
        try container.encode(version, forKey: .version)
        try container.encode(language, forKey: .language)
        try container.encode(baseUrl, forKey: .baseUrl)
        try container.encode(streamType, forKey: .streamType)
        try container.encode(quality, forKey: .quality)
        try container.encode(searchBaseUrl, forKey: .searchBaseUrl)
        try container.encode(scriptUrl, forKey: .scriptUrl)
        try container.encodeIfPresent(asyncJS, forKey: .asyncJS)
        try container.encodeIfPresent(streamAsyncJS, forKey: .streamAsyncJS)
        try container.encodeIfPresent(softsub, forKey: .softsub)
        try container.encodeIfPresent(multiStream, forKey: .multiStream)
        try container.encodeIfPresent(multiSubs, forKey: .multiSubs)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(novel, forKey: .novel)
    }
}

public enum ModuleType: String, Codable, CaseIterable, Sendable {
    case anime = "anime"
    case movies = "movies"
    case shows = "shows"
    case novels = "novels"
    case unknown = "unknown"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ModuleType(rawValue: raw.lowercased()) ?? .unknown
    }
}

public struct ScrapingModule: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let metadata: ModuleMetadata
    public let localPath: String
    public let metadataUrl: String
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        metadata: ModuleMetadata,
        localPath: String,
        metadataUrl: String,
        isActive: Bool = false
    ) {
        self.id = id
        self.metadata = metadata
        self.localPath = localPath
        self.metadataUrl = metadataUrl
        self.isActive = isActive
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: ScrapingModule, rhs: ScrapingModule) -> Bool {
        lhs.id == rhs.id
    }
}

public struct SearchResult: Codable, Hashable, Sendable {
    public let title: String
    public let image: String
    public let href: String

    public init(title: String, image: String, href: String) {
        self.title = title
        self.image = image
        self.href = href
    }
}

public struct MediaDetails: Codable, Hashable, Sendable {
    public let description: String
    public let aliases: String
    public let airdate: String

    public init(description: String, aliases: String, airdate: String) {
        self.description = description
        self.aliases = aliases
        self.airdate = airdate
    }
}

public struct EpisodeLink: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let number: Int
    public let title: String
    public let href: String
    public let duration: Int?

    public init(
        id: UUID = UUID(),
        number: Int,
        title: String = "",
        href: String,
        duration: Int? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.href = href
        self.duration = duration
    }
}

public struct StreamResult: Codable, Hashable, Sendable {
    public let streams: [StreamSource]?
    public let subtitles: [SubtitleTrack]?

    public init(streams: [StreamSource]? = nil, subtitles: [SubtitleTrack]? = nil) {
        self.streams = streams
        self.subtitles = subtitles
    }
}

public struct StreamSource: Codable, Hashable, Sendable {
    public let url: String
    public let headers: [String: String]?
    public let quality: String?
    public let type: String?

    public init(url: String, headers: [String: String]? = nil, quality: String? = nil, type: String? = nil) {
        self.url = url
        self.headers = headers
        self.quality = quality
        self.type = type
    }
}

public struct SubtitleTrack: Codable, Hashable, Sendable {
    public let url: String
    public let language: String?
    public let label: String?
    public let kind: String?

    public init(url: String, language: String? = nil, label: String? = nil, kind: String? = nil) {
        self.url = url
        self.language = language
        self.label = label
        self.kind = kind
    }
}

public struct Chapter: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let number: Int
    public let title: String
    public let href: String
    public let updatedAt: Date?

    public init(
        id: UUID = UUID(),
        number: Int,
        title: String,
        href: String,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.href = href
        self.updatedAt = updatedAt
    }
}

public struct ChapterContent: Codable, Hashable, Sendable {
    public let html: String
    public let nextChapterUrl: String?
    public let prevChapterUrl: String?

    public init(html: String, nextChapterUrl: String? = nil, prevChapterUrl: String? = nil) {
        self.html = html
        self.nextChapterUrl = nextChapterUrl
        self.prevChapterUrl = prevChapterUrl
    }
}