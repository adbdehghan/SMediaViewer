//
//  HLSAssetManager.swift
//  SMediaViewer
//
//  Created by Adib Dehghan on 6/2/25.
//

import AVFoundation
import OrderedCollections // From swift-collections package

final class HLSAssetManager: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    static let shared = HLSAssetManager()

    private let accessQueue = DispatchQueue(label: "com.yourcompany.hlsassetmanager.accessqueue")
    private var downloadSession: AVAssetDownloadURLSession!
    private var activeDownloadTasks: [URL: AVAssetDownloadTask] = [:]
    private var localAssetLocations: [URL: URL] = [:]
    private var preloadingURLs: OrderedSet<URL> = [] // URLs actively being downloaded or queued

    private let maxConcurrentPreloads = 2 // Number of HLS streams to preload concurrently
    private let hlsCacheDirectoryName = "HLSPreloadCache_v1"
    private var hlsCacheDirectoryURL: URL
    public var maxHLSCacheSizeInBytes: Int64 = 300 * 1024 * 1024 // 300MB for HLS preloads

    private lazy var delegateCallbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.yourcompany.hlsassetmanager.delegatequeue"
        queue.maxConcurrentOperationCount = 1 // Process delegate callbacks serially
        return queue
    }()

    private override init() {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // Using Application Support for more persistent storage if desired, or Caches.
        self.hlsCacheDirectoryURL = appSupportURL.appendingPathComponent(hlsCacheDirectoryName)
        
        super.init()
        
        try? FileManager.default.createDirectory(at: self.hlsCacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourcompany.hlsassetmanager.maindownloader")
        // config.isDiscretionary = false // For preloading, we might want it less discretionary
        // config.sessionSendsLaunchEvents = true // For true background completion
        self.downloadSession = AVAssetDownloadURLSession(configuration: config,
                                                         assetDownloadDelegate: self,
                                                         delegateQueue: delegateCallbackQueue)
        loadPersistedLocationsFromDisk()
        print("📼 HLSAssetManager initialized. Cache path: \(self.hlsCacheDirectoryURL.path)")
        cleanupHLSDiskCache() // Initial cleanup
    }
    
    // MARK: - Persistence (Simple UserDefaults example, consider a more robust solution for production)
    private func persistedLocationsFilePath() -> URL {
        hlsCacheDirectoryURL.appendingPathComponent("hls_locations.json")
    }

    private func loadPersistedLocationsFromDisk() {
        accessQueue.sync { // Ensure this is done before manager is used
            let path = persistedLocationsFilePath()
            guard FileManager.default.fileExists(atPath: path.path),
                  let data = try? Data(contentsOf: path),
                  let decoded = try? JSONDecoder().decode([URL: URL].self, from: data) else {
                localAssetLocations = [:]
                return
            }
            // Validate that files still exist
            var validLocations: [URL: URL] = [:]
            for (originalURL, localURL) in decoded {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    validLocations[originalURL] = localURL
                }
            }
            localAssetLocations = validLocations
            print("💾 HLS locations loaded from disk: \(localAssetLocations.count) items.")
        }
    }

    private func savePersistedLocationsToDisk() { // Call on accessQueue
        let path = persistedLocationsFilePath()
        do {
            let data = try JSONEncoder().encode(localAssetLocations)
            try data.write(to: path, options: .atomic)
            print("💾 HLS locations saved to disk.")
        } catch {
            print("❌ Error saving HLS locations: \(error)")
        }
    }

    // MARK: - Public API
    public func updatePreloadQueue(nextPotentialHLSURLs: [URL]) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Add new URLs to the end if they are not already downloaded, active, or in queue
            for url in nextPotentialHLSURLs {
                if url.pathExtension.lowercased() == "m3u8" &&
                   self.localAssetLocations[url] == nil &&
                   self.activeDownloadTasks[url] == nil {
                    self.preloadingURLs.append(url) // OrderedSet handles duplicates
                }
            }
            self.startNextPreloadsIfNeeded()
        }
    }

    public func getLocalAssetURL(for remoteHLSURL: URL) -> URL? {
        accessQueue.sync { localAssetLocations[remoteHLSURL] }
    }

    public func cancelPreloading(for url: URL) {
        accessQueue.async { [weak self] in
            self?.preloadingURLs.remove(url)
            if let task = self?.activeDownloadTasks.removeValue(forKey: url) {
                task.cancel()
                print("ℹ️ HLS Preload cancelled for: \(url.lastPathComponent)")
            }
        }
    }
    
    public func cancelAllPreloading() {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self.preloadingURLs.removeAll()
            for task in self.activeDownloadTasks.values { task.cancel() }
            self.activeDownloadTasks.removeAll()
            print("ℹ️ All HLS preloads cancelled.")
        }
    }

    // MARK: - Download Management
    private func startNextPreloadsIfNeeded() { // Call on accessQueue
        let currentActiveCount = activeDownloadTasks.count // Simpler count of tasks we've initiated
        guard currentActiveCount < maxConcurrentPreloads else { return }

        let neededToStart = maxConcurrentPreloads - currentActiveCount
        var startedCount = 0

        for urlToPreload in preloadingURLs { // Iterate in order
            if startedCount >= neededToStart { break }

            if localAssetLocations[urlToPreload] == nil && activeDownloadTasks[urlToPreload] == nil {
                let asset = AVURLAsset(url: urlToPreload)
                guard let task = downloadSession.makeAssetDownloadTask(asset: asset,
                                                                      assetTitle: urlToPreload.lastPathComponent,
                                                                      assetArtworkData: nil,
                                                                      options: [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 2_000_000]) // Example: Download at least 2Mbps variant
                else {
                    print("❌ HLSAssetManager: Unable to create download task for \(urlToPreload.lastPathComponent)"); continue
                }
                
                activeDownloadTasks[urlToPreload] = task
                task.resume()
                startedCount += 1
                print("▶️ HLS Preload task initiated for: \(urlToPreload.lastPathComponent)")
            }
        }
        // Remove started items from the front of the queue
        for url in activeDownloadTasks.keys { preloadingURLs.remove(url) }
    }

    // MARK: - AVAssetDownloadDelegate
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let originalURL = assetDownloadTask.urlAsset.url // This is the original remote HLS URL
        
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            
            // --- CORRECTED LINE ---
            // Convert the URL's absoluteString to Data for hashing
            let urlStringData = originalURL.absoluteString.data(using: .utf8)! // Force unwrap if you are certain originalURL.absoluteString is always valid UTF-8

            let destinationFilename = (originalURL.lastPathComponent.isEmpty ? UUID().uuidString : originalURL.lastPathComponent) + "_" + urlStringData.sha256().hexEncodedString().prefix(8) + ".movpkg"
            let persistentLocation = self.hlsCacheDirectoryURL.appendingPathComponent(destinationFilename)

            do {
                if FileManager.default.fileExists(atPath: persistentLocation.path) {
                    try FileManager.default.removeItem(at: persistentLocation)
                }
                try FileManager.default.moveItem(at: location, to: persistentLocation)
                
                self.localAssetLocations[originalURL] = persistentLocation
                self.savePersistedLocationsToDisk() // Ensure this method is implemented correctly
                print("✅ HLS Asset downloaded: \(originalURL.lastPathComponent) -> \(persistentLocation.lastPathComponent)")
            } catch {
                print("❌ HLSAssetManager: Error moving downloaded file: \(error) for \(originalURL.lastPathComponent)")
            }
            
            self.activeDownloadTasks.removeValue(forKey: originalURL)
            self.startNextPreloadsIfNeeded()
            self.cleanupHLSDiskCache()
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let assetDownloadTask = task as? AVAssetDownloadTask else { return }
        let originalURL = assetDownloadTask.urlAsset.url

        accessQueue.async { [weak self] in
            guard let self = self else { return }
            if let nsError = error as NSError?, !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                 print("❌ HLS Download task failed for \(originalURL.lastPathComponent): \(error!.localizedDescription)")
            } else if error == nil {
                 // This case should ideally be handled by didFinishDownloadingTo,
                 // but if no error, it means successful completion.
                 // If didFinishDownloadingTo was not called, something is amiss.
            }
            self.activeDownloadTasks.removeValue(forKey: originalURL)
            self.startNextPreloadsIfNeeded()
        }
    }
    
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let percentComplete = totalTimeRangesLoaded.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds } / timeRangeExpectedToLoad.duration.seconds * 100
        let originalURL = assetDownloadTask.urlAsset.url
        if !percentComplete.isNaN && percentComplete.isFinite {
             print(String(format: "⏳ HLS Download Progress for %@: %.2f%%", originalURL.lastPathComponent, percentComplete))
        }
    }

    // MARK: - HLS Disk Cache Cleanup (LRU)
    private func cleanupHLSDiskCache() { // Call on accessQueue
        var filesWithAttributes: [(url: URL, date: Date, size: Int64)] = []
        guard let enumerator = FileManager.default.enumerator(at: hlsCacheDirectoryURL, includingPropertiesForKeys: [.contentModificationDateKey, .totalFileSizeKey, .isDirectoryKey], options: .skipsHiddenFiles) else { return }

        var currentSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let resources = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .totalFileSizeKey, .contentModificationDateKey]),
                  !(resources.isDirectory ?? true), let fileSize = resources.totalFileSize, let modDate = resources.contentModificationDate else { continue }
            filesWithAttributes.append((url: fileURL, date: modDate, size: Int64(fileSize)))
            currentSize += Int64(fileSize)
        }

        if currentSize < maxHLSCacheSizeInBytes { return }
        print("🧹 HLS Cache (\(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))) exceeds limit. Cleaning...")
        filesWithAttributes.sort { $0.date < $1.date } // LRU

        for fileInfo in filesWithAttributes where currentSize > maxHLSCacheSizeInBytes {
            do {
                try FileManager.default.removeItem(at: fileInfo.url)
                currentSize -= fileInfo.size
                if let keyToRemove = localAssetLocations.first(where: { $0.value.standardizedFileURL == fileInfo.url.standardizedFileURL })?.key {
                    localAssetLocations.removeValue(forKey: keyToRemove)
                }
                print("🗑️ Evicted HLS: \(fileInfo.url.lastPathComponent)")
            } catch { print("❌ Error evicting HLS asset \(fileInfo.url.lastPathComponent): \(error)") }
        }
        savePersistedLocationsToDisk() // Update persisted list after cleanup
    }
    
    public func clearHLSCache(completion: (() -> Void)? = nil) {
        accessQueue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion?() }; return }
            self.cancelAllPreloading() // Cancel ongoing
            self.localAssetLocations.removeAll()
            if FileManager.default.fileExists(atPath: self.hlsCacheDirectoryURL.path) {
                do {
                    try FileManager.default.removeItem(at: self.hlsCacheDirectoryURL)
                    try FileManager.default.createDirectory(at: self.hlsCacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                    print("🧹 HLS Preload Cache cleared.")
                } catch { print("❌ Error clearing HLS cache directory: \(error)") }
            }
            self.savePersistedLocationsToDisk()
            DispatchQueue.main.async { completion?() }
        }
    }
}
