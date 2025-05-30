//
//  PlaybackTimeCache.swift
//  SMediaViewer
//
//  Created by Adib Dehghan on 5/30/25.
//

import Foundation
import CoreMedia // For CMTime

/// An actor that provides a concurrency-safe, in-memory cache for storing video playback progress.
/// This replaces NSCache to be fully compliant with Swift's Sendable checks.
actor PlaybackTimeCache {
    /// A shared singleton instance for global access.
    static let shared = PlaybackTimeCache()

    private var cache: [URL: CMTime] = [:]

    // A private initializer to enforce the singleton pattern.
    private init() {}

    /// Saves the playback time for a given URL.
    func setTime(_ time: CMTime, for url: URL) {
        cache[url] = time
    }

    /// Retrieves the saved playback time for a given URL.
    func getTime(for url: URL) -> CMTime? {
        return cache[url]
    }
    
    /// Clears the entire cache.
    func clear() {
        cache.removeAll()
    }
}
