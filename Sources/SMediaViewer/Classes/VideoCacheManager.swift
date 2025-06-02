//
//  VideoCacheManager.swift
//  SMediaViewer
//
//  Created by Adib.
//

import AVFoundation
import MobileCoreServices // For UTType constants if still needed, or UniformTypeIdentifiers

final class VideoCacheManager: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = VideoCacheManager()
    
    let customScheme = "cachingvideoscheme" // Custom scheme
    private let cacheDirectory: URL
    private let metadataDirectory: URL
    private var activeOperations: [URL: VideoDataOperation] = [:]
    private let accessQueue = DispatchQueue(label: "com.yourcompany.videocachemanager.accessqueue")    
    public var maxCacheSizeInBytes: Int64 = 500 * 1024 * 1024 // 500 MB
    private let preferredCacheFolderName = "AdvancedVideoCache_MP4_v1"
    
    private override init() {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let baseCacheURL = cachesURL.appendingPathComponent(preferredCacheFolderName)
        self.cacheDirectory = baseCacheURL.appendingPathComponent("Data")
        self.metadataDirectory = baseCacheURL.appendingPathComponent("Metadata")
        
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.createDirectory(at: self.metadataDirectory, withIntermediateDirectories: true, attributes: nil)
        
        super.init()
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.accessQueue.async {[weak self] in// Ensure cleanup logic itself is on accessQueue
                self?.cleanupCache()
            }
        }
        print("📼 AdvancedVideoCache initialized. Path: \(baseCacheURL.path)")
    }
    
    func assetURL(for originalURL: URL) -> URL? {
        guard let scheme = originalURL.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            print("⚠️ Original URL scheme is not http/https, cannot apply custom caching scheme: \(originalURL)")
            return originalURL
        }
        return URL(string: "\(customScheme):\(originalURL.absoluteString)")
    }
    
    private func originalURL(from customSchemeURL: URL) -> URL? {
        guard customSchemeURL.scheme == customScheme else { return nil }
        let originalURLString = customSchemeURL.absoluteString.replacingOccurrences(of: "\(customScheme):", with: "", options: .anchored)
        return URL(string: originalURLString)
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url, let originalURL = originalURL(from: requestURL) else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: nil))
            return false
        }
        
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            
            if self.tryFulfillFromCache(loadingRequest: loadingRequest, for: originalURL) {
                return
            }
            
            let operation: VideoDataOperation
            if let existingOperation = self.activeOperations[originalURL] {
                operation = existingOperation
            } else {
                operation = VideoDataOperation(originalURL: originalURL, cacheManager: self)
                self.activeOperations[originalURL] = operation
            }
            operation.add(loadingRequest: loadingRequest)
        }
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let requestURL = loadingRequest.request.url, let originalURL = originalURL(from: requestURL) else { return }
        accessQueue.async { [weak self] in
            self?.activeOperations[originalURL]?.cancel(loadingRequest: loadingRequest)
        }
    }
    
    // MARK: - Internal Cache Logic (called by VideoDataOperation)
    func operation(_ operation: VideoDataOperation, didReceiveResponse response: URLResponse) {
        accessQueue.async { [weak self] in
            guard let self = self, let httpResponse = response as? HTTPURLResponse, let url = response.url else { return }
            
            var totalLength: Int64 = 0
            if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String { // e.g., "bytes 200-1000/67589"
                if let totalStr = contentRange.components(separatedBy: "/").last, let total = Int64(totalStr) {
                    totalLength = total
                }
            }
            if totalLength == 0 {
                totalLength = httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : (response.expectedContentLength > 0 ? response.expectedContentLength : 0)
            }
            
            let mimeType = response.mimeType ?? "application/octet-stream"
            
            var metadata = self.loadMetadata(for: url) // Use the operation's original URL if response.url is different
            if metadata == nil {
                let fileName = self.cacheFileName(for: operation.originalURL) // Use operation's original URL for filename consistency
                metadata = VideoCacheItemMetadata(originalURL: operation.originalURL, totalLength: totalLength, mimeType: mimeType, downloadedRanges: [], lastAccessDate: Date(), localFileName: fileName)
            } else {
                if metadata!.totalLength == 0 && totalLength > 0 { metadata!.totalLength = totalLength }
                metadata!.lastAccessDate = Date()
            }
            self.saveMetadata(metadata!)
            
            let acceptRanges = httpResponse.allHeaderFields["Accept-Ranges"] as? String
            operation.updateContentInformation(totalLength: totalLength, mimeType: mimeType, isByteRangeAccessSupported: acceptRanges == "bytes")
        }
    }
    
    func operation(_ operation: VideoDataOperation, didReceiveData data: Data, atOffset offset: Int64) {
        accessQueue.async { [weak self] in
            guard let self = self, var metadata = self.loadMetadata(for: operation.originalURL) else { return }
            
            let filePath = self.cacheDirectory.appendingPathComponent(metadata.localFileName)
            do {
                let fileHandle: FileHandle
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    if metadata.totalLength > 0 { // Pre-allocate file size if known, can help with fragmentation
                        // FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)
                        // let emptyData = Data(count: Int(metadata.totalLength))
                        // try emptyData.write(to: filePath)
                        // Simpler: just create empty and let it grow
                        FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)
                    } else {
                        FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)
                    }
                }
                fileHandle = try FileHandle(forWritingTo: filePath)
                
                fileHandle.seek(toFileOffset: UInt64(offset))
                fileHandle.write(data)
                // Consider if synchronize is needed for every write; it can be slow.
                // try fileHandle.synchronize()
                fileHandle.closeFile()
                
                let receivedRange = NSRange(location: Int(offset), length: data.count)
                metadata.downloadedRanges = self.mergeRanges(metadata.downloadedRanges, withNewRange: receivedRange)
                metadata.lastAccessDate = Date()
                self.saveMetadata(metadata)
                
                operation.processPendingRequests()
                
            } catch {
                print("❌ Error writing to cache file \(filePath.lastPathComponent): \(error)")
                operation.failPendingRequests(with: error)
            }
        }
    }
    
    func operationDidComplete(_ operation: VideoDataOperation, error: Error?) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            if error == nil {
                if var metadata = self.loadMetadata(for: operation.originalURL) {
                    metadata.lastAccessDate = Date()
                    self.saveMetadata(metadata)
                    print("✅ Operation for \(operation.originalURL.lastPathComponent) completed successfully. Fully downloaded: \(metadata.isFullyDownloaded)")
                }
            } else {
                print("🔴 Operation for \(operation.originalURL.lastPathComponent) completed with error: \(error!.localizedDescription)")
            }
            // Trigger cache cleanup less aggressively, perhaps periodically or on app lifecycle events.
            // For now, let's do it if no error, as a file might have grown.
            if error == nil {
                self.cleanupCache()
            }
            self.activeOperations[operation.originalURL] = nil
        }
    }
    
    // MARK: - Cache File & Metadata Management
    internal func cacheFileName(for url: URL) -> String {
        let unsafeChars = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let safePathComponent = url.lastPathComponent.components(separatedBy: unsafeChars).joined(separator: "_")
        let hash = url.absoluteString.data(using: .utf8)!.sha256().hexEncodedString().prefix(16) // Short hash
        return "\(hash)_\(safePathComponent).mp4"
    }
    
    private func metadataFilePath(for originalURL: URL) -> URL {
        let fileName = cacheFileName(for: originalURL) + ".meta"
        return metadataDirectory.appendingPathComponent(fileName)
    }
    
    internal func loadMetadata(for originalURL: URL) -> VideoCacheItemMetadata? { // Call on accessQueue
        let filePath = metadataFilePath(for: originalURL)
        guard FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              let metadata = try? JSONDecoder().decode(VideoCacheItemMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }
    
    internal func saveMetadata(_ metadata: VideoCacheItemMetadata) { // Call on accessQueue
        let filePath = metadataFilePath(for: metadata.originalURL)
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: filePath, options: .atomic)
        } catch {
            print("❌ Error saving metadata for \(metadata.originalURL.lastPathComponent): \(error)")
        }
    }
    
    internal func dataFilePath(for metadata: VideoCacheItemMetadata) -> URL {
        return cacheDirectory.appendingPathComponent(metadata.localFileName)
    }
    
    private func mergeRanges(_ ranges: [NSRange], withNewRange newRange: NSRange) -> [NSRange] { // Call on accessQueue
        var allRanges = ranges + [newRange]
        allRanges.removeAll { $0.length == 0 } // Remove zero-length ranges
        allRanges.sort { $0.location < $1.location }
        
        var merged: [NSRange] = []
        guard var currentMerge = allRanges.first else { return [] }
        
        for i in 1..<allRanges.count {
            let nextRange = allRanges[i]
            if NSMaxRange(currentMerge) >= nextRange.location {
                currentMerge.length = max(NSMaxRange(currentMerge), NSMaxRange(nextRange)) - currentMerge.location
            } else {
                merged.append(currentMerge)
                currentMerge = nextRange
            }
        }
        merged.append(currentMerge)
        return merged
    }
    
    internal func tryFulfillFromCache(loadingRequest: AVAssetResourceLoadingRequest, for originalURL: URL) -> Bool { // Call on accessQueue
        guard let metadata = loadMetadata(for: originalURL), metadata.totalLength > 0 else { return false }
        
        if let infoRequest = loadingRequest.contentInformationRequest {
            if infoRequest.contentType == nil {
                if let type = UTType(mimeType: metadata.mimeType) { // Need UniformTypeIdentifiers import
                    infoRequest.contentType = type.identifier
                } else {
                    infoRequest.contentType = nil
                }
                infoRequest.contentLength = metadata.totalLength
                infoRequest.isByteRangeAccessSupported = true
            }
        }
        
        guard let dataRequest = loadingRequest.dataRequest else {
            return false
        }
        
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = dataRequest.requestedLength
        var currentOffsetInRequest = dataRequest.currentOffset
        let requestedEnd = requestedOffset + Int64(requestedLength)
        var fulfilledFromCache = false
        
        do {
            let fileHandle = try FileHandle(forReadingFrom: dataFilePath(for: metadata))
            defer { fileHandle.closeFile() }
            
            for cachedRange in mergeRanges(metadata.downloadedRanges, withNewRange: NSRange()) {
                let rangeStartInCache = Int64(cachedRange.location)
                let rangeEndInCache = Int64(cachedRange.location + cachedRange.length)
                let effectiveReadOffset = max(currentOffsetInRequest, rangeStartInCache)
                let effectiveReadEnd = min(requestedEnd, rangeEndInCache)
                
                if effectiveReadOffset < effectiveReadEnd {
                    let lengthToProvide = Int(effectiveReadEnd - effectiveReadOffset)
                    if lengthToProvide > 0 {
                        fileHandle.seek(toFileOffset: UInt64(effectiveReadOffset))
                        let data = fileHandle.readData(ofLength: lengthToProvide)
                        dataRequest.respond(with: data)
                        currentOffsetInRequest += Int64(data.count)
                        if currentOffsetInRequest >= requestedEnd { break }
                    }
                }
            }
            
            if currentOffsetInRequest >= requestedEnd {
                if !loadingRequest.isFinished { loadingRequest.finishLoading() }
                fulfilledFromCache = true
            } else if dataRequest.requestsAllDataToEndOfResource && metadata.isFullyDownloaded && currentOffsetInRequest >= metadata.totalLength {
                if !loadingRequest.isFinished { loadingRequest.finishLoading() }
                fulfilledFromCache = true
            }
            
            if fulfilledFromCache {
                self.accessQueue.async { [weak self] in // Dispatch to avoid blocking the delegate return
                    if var updatedMetadata = self?.loadMetadata(for: originalURL) {
                        updatedMetadata.lastAccessDate = Date()
                        self?.saveMetadata(updatedMetadata)
                    }
                }
            }
        } catch {
            print("❌ Error reading from cache for \(originalURL.lastPathComponent): \(error)")
            if !loadingRequest.isFinished { loadingRequest.finishLoading(with: error) }
            return true
        }
        return fulfilledFromCache
    }
    
    // MARK: - Cache Cleanup
    private func cleanupCache() { // Must be called on accessQueue
        var allMetadataItems: [VideoCacheItemMetadata] = []
        
        guard let metadataFiles = try? FileManager.default.contentsOfDirectory(at: self.metadataDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return
        }
        
        for fileURL in metadataFiles where fileURL.pathExtension == "meta" {
            if let data = try? Data(contentsOf: fileURL),
               let meta = try? JSONDecoder().decode(VideoCacheItemMetadata.self, from: data) {
                allMetadataItems.append(meta)
            }
        }
        
        var currentCacheSize: Int64 = allMetadataItems.reduce(0) { size, meta in
            let dataFileURL = self.dataFilePath(for: meta)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: dataFileURL.path) {
                return size + (attributes[.size] as? Int64 ?? 0)
            }
            return size
        }
        
        if currentCacheSize < maxCacheSizeInBytes {
            print("ℹ️ Cache size is \(ByteCountFormatter.string(fromByteCount: currentCacheSize, countStyle: .file)). No cleanup needed.")
            return
        }
        
        print("🧹 Cache size (\(ByteCountFormatter.string(fromByteCount: currentCacheSize, countStyle: .file))) exceeds limit. Cleaning up...")
        
        // Sort by last access date (oldest first) for LRU eviction.
        allMetadataItems.sort { $0.lastAccessDate < $1.lastAccessDate }
        
        for meta in allMetadataItems {
            if currentCacheSize > maxCacheSizeInBytes {
                let dataFileURL = self.dataFilePath(for: meta)
                let metadataFileURL = self.metadataFilePath(for: meta.originalURL)
                
                do {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: dataFileURL.path),
                       let fileSize = attributes[.size] as? Int64 {
                        try FileManager.default.removeItem(at: dataFileURL)
                        try FileManager.default.removeItem(at: metadataFileURL)
                        currentCacheSize -= fileSize
                        print("🗑️ Evicted \(meta.localFileName) (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))) from cache.")
                    } else { // If data file doesn't exist, just clean up metadata
                        try FileManager.default.removeItem(at: metadataFileURL)
                    }
                } catch {
                    print("❌ Error removing \(meta.localFileName) from cache: \(error)")
                }
            } else {
                break
            }
        }
        print("🧹 Cache cleanup complete. Final size: \(ByteCountFormatter.string(fromByteCount: currentCacheSize, countStyle: .file))")
    }
    
    public func clearAllCache(completion: (() -> Void)? = nil) {
        accessQueue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion?() }; return }
            do {
                // First, invalidate all active operations
                self.activeOperations.values.forEach { $0.invalidateAndCancelSession() }
                self.activeOperations.removeAll() // Clear the dictionary
                
                // Wait a moment for sessions to be invalidated if needed, or use completion handlers.
                // For simplicity, directly remove directories.
                if FileManager.default.fileExists(atPath: self.cacheDirectory.path) {
                    try FileManager.default.removeItem(at: self.cacheDirectory)
                }
                if FileManager.default.fileExists(atPath: self.metadataDirectory.path) {
                    try FileManager.default.removeItem(at: self.metadataDirectory)
                }
                
                try FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true, attributes: nil)
                try FileManager.default.createDirectory(at: self.metadataDirectory, withIntermediateDirectories: true, attributes: nil)
                print("📼 Advanced Video Cache cleared.")
            } catch {
                print("❌ Error clearing advanced video cache: \(error)")
            }
            DispatchQueue.main.async { completion?() }
        }
    }
}
