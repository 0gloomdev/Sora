//
//  ModuleCacheManager.swift
//  Sora
//
//  Created by Sora Team on 18/09/26.
//

import Foundation
import GRDB
import os
import CryptoKit

/// Manages persistent caching of JS modules for offline browsing.
/// Uses GRDB (SQLite) for metadata + file system for script content.
@MainActor
public final class ModuleCacheManager {
    public static let shared = ModuleCacheManager()

    private let logger = os.Logger(subsystem: "com.sora.cache", category: "ModuleCache")
    private let dbQueue: DatabaseQueue
    private let cacheDirectory: URL
    private let maxCacheSizeBytes: Int64 = 100 * 1024 * 1024 // 100 MB default

    private init?() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let cacheDir = appSupport.appendingPathComponent("ModuleCache", isDirectory: true)
        self.cacheDirectory = cacheDir

        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let dbURL = cacheDir.appendingPathComponent("module_cache.sqlite")
        do {
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try migrateIfNeeded()
        } catch {
            return nil
        }
    }

    /// Schema version for migrations
    private static let currentSchemaVersion = 1

    /// Migrate database schema if needed
    private func migrateIfNeeded() throws {
        try dbQueue.write { db in
            try db.create(table: "module_cache", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("source_name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("script_hash", .text).notNull()
                t.column("script_path", .text).notNull()
                t.column("metadata_json", .text).notNull()
                t.column("last_fetched", .integer).notNull()
                t.column("etag", .text)
                t.column("last_modified", .text)
                t.column("is_valid", .boolean).notNull().defaults(to: true)
                t.column("created_at", .integer).defaults(to: Date().timeIntervalSince1970)
            }
            try db.create(index: "idx_module_cache_valid", on: "module_cache", columns: ["is_valid"], ifNotExists: true)
        }
    }

    /// Result of cache validation against remote
    public struct CacheValidationResult {
        public let isUpToDate: Bool
        public let newVersion: String?
        public let etag: String?
        public let lastModified: String?
        public let scriptContent: String?

        public init(isUpToDate: Bool, newVersion: String? = nil, etag: String? = nil, lastModified: String? = nil, scriptContent: String? = nil) {
            self.isUpToDate = isUpToDate
            self.newVersion = newVersion
            self.etag = etag
            self.lastModified = lastModified
            self.scriptContent = scriptContent
        }
    }

    /// Errors specific to cache operations
    public enum CacheError: Error, LocalizedError, Sendable {
        case moduleNotFound
        case invalidMetadata
        case networkError(Error)
        case hashMismatch
        case ioError(Error)
        case databaseError(Error)

        public var errorDescription: String? {
            switch self {
            case .moduleNotFound: return "Module not found in cache"
            case .invalidMetadata: return "Invalid module metadata"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .hashMismatch: return "Script hash mismatch"
            case .ioError(let e): return "I/O error: \(e.localizedDescription)"
            case .databaseError(let e): return "Database error: \(e.localizedDescription)"
            }
        }
    }

    /// Retrieve a cached module by ID. Returns nil if not found or invalid.
    public func getCachedModule(id: UUID) async throws -> (script: String, metadata: ModuleMetadata)? {
        let idString = id.uuidString
        return try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db,
                sql: """
                SELECT script_path, metadata_json FROM module_cache
                WHERE id = ? AND is_valid = 1
                """,
                arguments: [idString]) else {
                return nil
            }

            let scriptPath: String = row["script_path"]
            let metadataJson: String = row["metadata_json"]

            let scriptURL = self.cacheDirectory.appendingPathComponent(scriptPath)
            guard let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
                throw CacheError.ioError(NSError(domain: "ModuleCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read script file"]))
            }

            let metadata = try JSONDecoder().decode(ModuleMetadata.self, from: Data(metadataJson.utf8))
            return (script, metadata)
        }
    }

    /// Save a module to cache (script content + metadata)
    public func saveModuleToCache(id: UUID, metadata: ModuleMetadata, script: String) async throws {
        let idString = id.uuidString
        let scriptData = script.data(using: .utf8)!
        let scriptHash = SHA256.hash(data: scriptData).map { String(format: "%02x", $0) }.joined()
        let fileName = "\(idString).js"
        let scriptURL = cacheDirectory.appendingPathComponent(fileName)

        // Write script to file
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let metadataJson = try JSONEncoder().encode(metadata)

        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO module_cache
                (id, source_name, version, script_hash, script_path, metadata_json, last_fetched, is_valid, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                """,
                arguments: [
                    idString,
                    metadata.sourceName,
                    metadata.version,
                    scriptHash,
                    fileName,
                    String(data: metadataJson, encoding: .utf8)!,
                    Date().timeIntervalSince1970,
                    Date().timeIntervalSince1970
                ])
        }

        // Enforce cache size limit
        try await enforceCacheSizeLimit()
    }

    /// Validate remote version against cache using conditional GET (ETag/Last-Modified)
    public func validateRemoteVersion(_ metadata: ModuleMetadata) async throws -> CacheValidationResult {
        guard let _ = URL(string: metadata.scriptUrl) else {
            throw CacheError.invalidMetadata
        }

        // Get cached ETag/Last-Modified
        let cached = try await dbQueue.read { db in
            try Row.fetchOne(db,
                sql: "SELECT etag, last_modified, version, script_hash, script_path FROM module_cache WHERE id = ? AND is_valid = 1",
                arguments: [metadata.id.uuidString])
        }

        var request = URLRequest(url: URL(string: metadata.scriptUrl)!)
        request.httpMethod = "HEAD"
        if let etag = cached?["etag"] as? String {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cached?["last_modified"] as? String {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (_, response) = try await URLSession.custom.data(for: URLRequest(url: URL(string: metadata.scriptUrl)!))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CacheError.networkError(NSError(domain: "ModuleCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]))
        }

        if httpResponse.statusCode == 304 {
            // Not modified - cache is up to date
            return CacheValidationResult(isUpToDate: true)
        }

        if httpResponse.statusCode == 200 {
            // Content changed - fetch new version
            let (data, _) = try await URLSession.custom.data(for: URLRequest(url: URL(string: metadata.scriptUrl)!))
            guard let newScript = String(data: data, encoding: .utf8) else {
                throw CacheError.networkError(NSError(domain: "ModuleCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode script"]))
            }

            let newETag = httpResponse.allHeaderFields["ETag"] as? String
            let newLastModified = httpResponse.allHeaderFields["Last-Modified"] as? String

            return CacheValidationResult(
                isUpToDate: false,
                newVersion: metadata.version,
                etag: newETag,
                lastModified: newLastModified,
                scriptContent: newScript
            )
        }

        throw CacheError.networkError(NSError(domain: "ModuleCache", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected status code"]))
    }

    /// Invalidate (soft delete) a module from cache
    public func invalidateModule(id: UUID) async throws {
        let idString = id.uuidString
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE module_cache SET is_valid = 0 WHERE id = ?", arguments: [idString])
        }
    }

    /// Enforce cache size limit by removing least recently used entries
    private func enforceCacheSizeLimit() async throws {
        var totalSize: Int64 = 0
        var entries: [(url: URL, size: Int64, lastAccess: Date)] = []

        // Calculate total size
        let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey])
        for url in contents where url.pathExtension == "js" {
            let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            let size = Int64(resources.fileSize ?? 0)
            let lastAccess = resources.contentAccessDate ?? Date.distantPast
            totalSize += size
            entries.append((url, size, lastAccess))
        }

        if totalSize <= maxCacheSizeBytes { return }

        // Sort by last access (oldest first) and remove until under limit
        entries.sort { $0.lastAccess < $1.lastAccess }
        var removedSize: Int64 = 0
        for entry in entries {
            if totalSize - removedSize <= maxCacheSizeBytes { break }
            let scriptPath = entry.url.lastPathComponent
            let moduleId = String(scriptPath.dropLast(3)) // remove .js

            // Soft delete from DB
            try await dbQueue.write { db in
                try db.execute(sql: "UPDATE module_cache SET is_valid = 0 WHERE script_path = ?", arguments: [scriptPath])
            }

            // Delete file
            try FileManager.default.removeItem(at: entry.url)
            removedSize += entry.size
            logger.info("Evicted module from cache: \(moduleId) (\(entry.size) bytes)")
        }
    }

    /// Get cache statistics
    public func getCacheStats() async throws -> (count: Int, totalSizeBytes: Int64) {
        let count = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM module_cache WHERE is_valid = 1") ?? 0
        }

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var totalSize: Int64 = 0
        for url in contents where url.pathExtension == "js" {
            totalSize += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        return (count, totalSize)
    }

    /// Clear all cached modules (hard delete)
    public func clearCache() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM module_cache")
        }
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for url in contents where url.pathExtension == "js" {
            try fileManager.removeItem(at: url)
        }
    }
}