//
//  HLSAssetManager.swift
//  SMediaViewer
//
//  Created by Adib Dehghan on 6/2/25.
//

import AVFoundation
import OrderedCollections // From swift-collections package

final public class HLSAssetManager: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
   public static let shared = HLSAssetManager()

    private let accessQueue = DispatchQueue(label: "com.yourcompany.hlsassetmanager.accessqueue", qos: .userInitiated)
    private var downloadSession: AVAssetDownloadURLSession!
    private var activeDownloadTasks: [URL: AVAssetDownloadTask] = [:]
    private var localAssetLocations: [URL: URL] = [:] // Maps original remote URL to local .movpkg URL
    private var preloadingURLs: OrderedSet<URL> = [] // URLs actively being downloaded or queued

    private let maxConcurrentPreloads = 2
    private let hlsCacheDirectoryName = "HLSPreloadCache_v2" // Changed version to ensure fresh cache with new logic
    private var hlsCacheDirectoryURL: URL
    public var maxHLSCacheSizeInBytes: Int64 = 300 * 1024 * 1024 // 300MB

    private lazy var delegateCallbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.yourcompany.hlsassetmanager.delegatequeue"
        queue.maxConcurrentOperationCount = 1 // Process delegate callbacks serially
        return queue
    }()

    private override init() {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.hlsCacheDirectoryURL = appSupportURL.appendingPathComponent(hlsCacheDirectoryName)
        
        super.init()
        
        do {
            try FileManager.default.createDirectory(at: self.hlsCacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ HLSAssetManager: Failed to create cache directory: \(error)")
        }
        
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourcompany.hlsassetmanager.maindownloader.v2")
        self.downloadSession = AVAssetDownloadURLSession(configuration: config,
                                                         assetDownloadDelegate: self,
                                                         delegateQueue: delegateCallbackQueue)
        loadPersistedLocationsFromDisk()
        print("📼 HLSAssetManager initialized. Cache path: \(self.hlsCacheDirectoryURL.path)")
        
        // Perform initial cleanup on a background thread to avoid blocking init
        accessQueue.async { [weak self] in
            self?.cleanupHLSDiskCache()
        }
    }
    
    // MARK: - Persistence
    private func persistedLocationsFilePath() -> URL {
        hlsCacheDirectoryURL.appendingPathComponent("hls_locations_v2.json")
    }

    private func loadPersistedLocationsFromDisk() {
        accessQueue.sync {
            let path = persistedLocationsFilePath()
            guard FileManager.default.fileExists(atPath: path.path),
                  let data = try? Data(contentsOf: path),
                  let decoded = try? JSONDecoder().decode([URL: URL].self, from: data) else {
                localAssetLocations = [:]
                return
            }
            var validLocations: [URL: URL] = [:]
            for (originalURL, localURL) in decoded {
                if FileManager.default.fileExists(atPath: localURL.path) {
                    validLocations[originalURL] = localURL
                } else {
                    print("🔎 HLS Location: \(localURL.lastPathComponent) for \(originalURL.lastPathComponent) not found on disk. Removing from persisted list.")
                }
            }
            localAssetLocations = validLocations
            print("💾 HLS locations loaded from disk: \(localAssetLocations.count) items.")
        }
    }

    private func savePersistedLocationsToDisk() { // Must be called on accessQueue
        let path = persistedLocationsFilePath()
        do {
            let data = try JSONEncoder().encode(localAssetLocations)
            try data.write(to: path, options: .atomic)
            // print("💾 HLS locations saved to disk.")
        } catch {
            print("❌ Error saving HLS locations: \(error)")
        }
    }

    // MARK: - Public API
    public func updatePreloadQueue(nextPotentialHLSURLs: [URL]) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            
            var addedToQueue = false
            for url in nextPotentialHLSURLs {
                if url.pathExtension.lowercased() == "m3u8" &&
                   self.localAssetLocations[url] == nil && // Not already downloaded and verified
                   self.activeDownloadTasks[url] == nil && // Not currently downloading
                   !self.preloadingURLs.contains(url) {    // Not already in the queue
                    self.preloadingURLs.append(url)
                    addedToQueue = true
                }
            }
            if addedToQueue {
                // print("➕ HLS URLs added to preload queue. Current queue size: \(self.preloadingURLs.count)")
            }
            self.startNextPreloadsIfNeeded()
        }
    }

    public func getLocalAssetURL(for remoteHLSURL: URL) -> URL? {
        accessQueue.sync { localAssetLocations[remoteHLSURL] }
    }

    public func cancelPreloading(for url: URL) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self.preloadingURLs.remove(url)
            if let task = self.activeDownloadTasks.removeValue(forKey: url) {
                task.cancel()
                print("ℹ️ HLS Preload task explicitly cancelled for: \(url.lastPathComponent)")
            }
        }
    }
    
    public func cancelAllPreloading() {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self.preloadingURLs.removeAll()
            for (_, task) in self.activeDownloadTasks { task.cancel() }
            self.activeDownloadTasks.removeAll()
            print("ℹ️ All HLS preloads cancelled.")
        }
    }

    // MARK: - Download Management
    private func startNextPreloadsIfNeeded() { // Must be called on accessQueue
        let currentActiveCount = activeDownloadTasks.count
        guard currentActiveCount < maxConcurrentPreloads else { return }

        let neededToStart = maxConcurrentPreloads - currentActiveCount
        var startedCount = 0
        
        // Iterate over a copy of preloadingURLs in case it's modified during iteration (though append is at end)
        let urlsToConsider = Array(preloadingURLs)

        for urlToPreload in urlsToConsider {
            if startedCount >= neededToStart { break }

            // Double check conditions as state might have changed
            if localAssetLocations[urlToPreload] == nil && activeDownloadTasks[urlToPreload] == nil {
                let asset = AVURLAsset(url: urlToPreload)
                // Consider adding AVURLAssetPreferPreciseDurationAndTimingKey if issues persist with seeking/duration
                // let asset = AVURLAsset(url: urlToPreload, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

                // Define download options. You can specify bitrates for variants.
                // For example, to download media with bitrates between 200Kbps and 1Mbps:
                // let options = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 200000,
                //                AVAssetDownloadTaskMaximumRequiredMediaBitrateKey: 1000000]
                // For simplicity, using a minimum bitrate.
                let options: [String: Any]? = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: 1_500_000] // Download at least 1.5Mbps variant

                guard let task = downloadSession.makeAssetDownloadTask(asset: asset,
                                                                      assetTitle: urlToPreload.lastPathComponent.isEmpty ? "UntitledHLS" : urlToPreload.lastPathComponent,
                                                                      assetArtworkData: nil, // Placeholder for artwork
                                                                      options: options)
                else {
                    print("❌ HLSAssetManager: Unable to create download task for \(urlToPreload.lastPathComponent). Removing from queue.")
                    self.preloadingURLs.remove(urlToPreload) // Remove problematic URL
                    continue
                }
                
                activeDownloadTasks[urlToPreload] = task
                task.resume() // Start the download
                startedCount += 1
                // print("▶️ HLS Preload task initiated for: \(urlToPreload.lastPathComponent)")
            }
        }
        // Remove URLs for which tasks have been successfully started from the preloading queue
        for url in activeDownloadTasks.keys {
            preloadingURLs.remove(url)
        }
    }

    // MARK: - AVAssetDownloadDelegate
    public func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let originalURL = assetDownloadTask.urlAsset.url
        
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            
            let urlStringData = originalURL.absoluteString.data(using: .utf8) ?? Data(UUID().uuidString.utf8) // Fallback if string conversion fails
            let safeOriginalName = originalURL.lastPathComponent.isEmpty ? "downloaded_hls" : originalURL.lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
            let destinationFilename = safeOriginalName + "_" + urlStringData.sha256().hexEncodedString().prefix(8) + ".movpkg"
            let persistentLocation = self.hlsCacheDirectoryURL.appendingPathComponent(destinationFilename)

            do {
                if FileManager.default.fileExists(atPath: persistentLocation.path) {
                    try FileManager.default.removeItem(at: persistentLocation)
                }
                try FileManager.default.moveItem(at: location, to: persistentLocation)
                // print("✅ HLS Asset downloaded (pre-verification): \(originalURL.lastPathComponent) -> \(persistentLocation.lastPathComponent)")

                // ** NEW: Verify playability of the downloaded .movpkg **
                let localAsset = AVURLAsset(url: persistentLocation)
                let requiredKeys = ["playable"] // "isPlayable" is the property, "playable" is the key for KVO/loading

                localAsset.loadValuesAsynchronously(forKeys: requiredKeys) { [weak self] in
                    guard let self = self else { return }
                    
                    // Ensure subsequent operations are on the accessQueue
                    self.accessQueue.async {
                        var assetError: NSError?
                        let playableStatus = localAsset.statusOfValue(forKey: "playable", error: &assetError)

                        if playableStatus == .loaded && localAsset.isPlayable {
                            // Asset is playable, proceed with caching
                            self.localAssetLocations[originalURL] = persistentLocation
                            self.savePersistedLocationsToDisk()
                            print("✅ HLS Asset VERIFIED PLAYABLE: \(originalURL.lastPathComponent) at \(persistentLocation.lastPathComponent)")
                        } else {
                            // Asset is not playable, delete it and log
                            print("❌ Downloaded HLS Asset at \(persistentLocation.lastPathComponent) for \(originalURL.lastPathComponent) is NOT PLAYABLE after download. Status: \(playableStatus.rawValue). Error: \(assetError?.localizedDescription ?? "Unknown"). Deleting.")
                            do {
                                try FileManager.default.removeItem(at: persistentLocation)
                            } catch {
                                print("❌ Error deleting non-playable HLS asset \(persistentLocation.lastPathComponent): \(error)")
                            }
                            // Do NOT add to localAssetLocations
                        }
                        
                        // Common task completion regardless of playability outcome
                        self.activeDownloadTasks.removeValue(forKey: originalURL)
                        self.startNextPreloadsIfNeeded()
                        self.cleanupHLSDiskCache() // Clean up cache after potential changes
                    }
                }
                // Note: The task removal and next preload start are now inside the async verification block.
                // This means they wait until verification is complete.

            } catch {
                print("❌ HLSAssetManager: Error moving downloaded file: \(error) for \(originalURL.lastPathComponent)")
                // If moving fails, still remove from active tasks and try next.
                self.activeDownloadTasks.removeValue(forKey: originalURL)
                self.startNextPreloadsIfNeeded()
            }
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let assetDownloadTask = task as? AVAssetDownloadTask else {
            // print("ℹ️ HLSAssetManager: Non-asset task completed (or cancelled).")
            return
        }
        let originalURL = assetDownloadTask.urlAsset.url

        accessQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If an error occurred (and it wasn't a cancellation), log it.
            // The didFinishDownloadingTo delegate is NOT called if an error occurs.
            if let nsError = error as NSError?, !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                 print("❌ HLS Download task FAILED for \(originalURL.lastPathComponent): \(nsError.localizedDescription)")
            } else if error == nil {
                 // This case should ideally be fully handled by didFinishDownloadingTo.
                 // If this is called with error == nil, it means the task itself completed without system error,
                 // but didFinishDownloadingTo is where the actual file handling and verification occurs.
                 // print("ℹ️ HLS Download task reported completion without error for \(originalURL.lastPathComponent), awaiting didFinishDownloadingTo.")
            }
            // Else, it was a cancellation, which is fine.
            
            // Always remove from active tasks and try to start next,
            // as this task (whether success, fail, or cancel) is now finished.
            // If successful, didFinishDownloadingTo will handle the actual asset.
            // If failed here, it won't be added to cache.
            if self.activeDownloadTasks[originalURL] != nil {
                 self.activeDownloadTasks.removeValue(forKey: originalURL)
                 self.startNextPreloadsIfNeeded()
            }
        }
    }
    
    public func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        // This delegate method can be used to update UI with download progress.
        // For simplicity in this manager, we'll just print it.
        let percentComplete = totalTimeRangesLoaded.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds } / timeRangeExpectedToLoad.duration.seconds * 100
        let originalURL = assetDownloadTask.urlAsset.url
        if !percentComplete.isNaN && percentComplete.isFinite {
             // print(String(format: "⏳ HLS Download Progress for %@: %.2f%%", originalURL.lastPathComponent, percentComplete))
        }
    }

    // MARK: - HLS Disk Cache Cleanup (LRU)
    private func cleanupHLSDiskCache() { // Must be called on accessQueue
        var filesWithAttributes: [(url: URL, date: Date, size: Int64)] = []
        
        guard FileManager.default.fileExists(atPath: hlsCacheDirectoryURL.path) else {
            // print("ℹ️ HLS Cache directory does not exist. Skipping cleanup.")
            return
        }

        do {
            let directoryContents = try FileManager.default.contentsOfDirectory(at: hlsCacheDirectoryURL,
                                                                                includingPropertiesForKeys: [.contentModificationDateKey, .totalFileSizeKey, .isDirectoryKey],
                                                                                options: .skipsHiddenFiles)
            var currentSize: Int64 = 0
            for fileURL in directoryContents {
                let resources = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .totalFileSizeKey, .contentModificationDateKey])
                if !(resources.isDirectory ?? true), let fileSize = resources.totalFileSize, let modDate = resources.contentModificationDate {
                    filesWithAttributes.append((url: fileURL, date: modDate, size: Int64(fileSize)))
                    currentSize += Int64(fileSize)
                }
            }

            if currentSize < maxHLSCacheSizeInBytes {
                // print("ℹ️ HLS Cache size (\(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))) is within limit. No cleanup needed.")
                return
            }
            
            print("🧹 HLS Cache (\(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))) exceeds limit (\(ByteCountFormatter.string(fromByteCount: maxHLSCacheSizeInBytes, countStyle: .file))). Cleaning...")
            filesWithAttributes.sort { $0.date < $1.date } // LRU: oldest first

            for fileInfo in filesWithAttributes where currentSize > maxHLSCacheSizeInBytes {
                do {
                    try FileManager.default.removeItem(at: fileInfo.url)
                    currentSize -= fileInfo.size
                    // Also remove from our in-memory map if this file was a cached asset's location
                    if let keyToRemove = localAssetLocations.first(where: { $0.value.standardizedFileURL == fileInfo.url.standardizedFileURL })?.key {
                        localAssetLocations.removeValue(forKey: keyToRemove)
                        // print("🗑️ Evicted HLS: \(fileInfo.url.lastPathComponent) (and removed from map for \(keyToRemove.lastPathComponent))")
                    } else {
                        // print("🗑️ Evicted HLS file (not in map): \(fileInfo.url.lastPathComponent)")
                    }
                } catch {
                    print("❌ Error evicting HLS asset \(fileInfo.url.lastPathComponent): \(error)")
                }
            }
            if localAssetLocations.values.count != filesWithAttributes.filter({ currentSize <= maxHLSCacheSizeInBytes && $0.size > 0}).count {
                 savePersistedLocationsToDisk() // Update persisted list if changes were made to mapped items
            }
            // print("🧹 HLS Cache cleanup complete. Final size: \(ByteCountFormatter.string(fromByteCount: currentSize, countStyle: .file))")

        } catch {
            print("❌ Error enumerating HLS cache directory for cleanup: \(error)")
        }
    }
    
    public func clearHLSCache(completion: (() -> Void)? = nil) {
        accessQueue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion?() }; return }
            
            self.cancelAllPreloading() // Cancel any ongoing downloads
            
            // Wait for cancellations to process before deleting files
            self.accessQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { DispatchQueue.main.async { completion?() }; return }
                
                self.localAssetLocations.removeAll()
                if FileManager.default.fileExists(atPath: self.hlsCacheDirectoryURL.path) {
                    do {
                        try FileManager.default.removeItem(at: self.hlsCacheDirectoryURL)
                        try FileManager.default.createDirectory(at: self.hlsCacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                        print("🧹 HLS Preload Cache cleared successfully.")
                    } catch {
                        print("❌ Error clearing HLS cache directory: \(error)")
                    }
                }
                self.savePersistedLocationsToDisk() // Save the empty locations
                DispatchQueue.main.async { completion?() }
            }
        }
    }
}

