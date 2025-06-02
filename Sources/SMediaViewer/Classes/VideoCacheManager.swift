//
//  VideoCacheManager.swift
//  SMediaViewer
//
//  Created by Adib.
//

//
//  VideoCacheManager.swift
//  SMediaViewer
//
//  Created by Adib.
//

import AVFoundation
import UniformTypeIdentifiers // For UTType constants

final public class VideoCacheManager: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
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
            self?.accessQueue.async {[weak self] in
                self?.cleanupCache()
            }
        }
        print("📼 AdvancedVideoCache initialized. Path: \(baseCacheURL.path)")
    }
    
    func assetURL(for originalURL: URL) -> URL? {
        guard let scheme = originalURL.scheme, ["http", "https"].contains(scheme.lowercased()) else {
            print("⚠️ Original URL scheme is not http/https, cannot apply custom caching scheme: \(originalURL)")
            return originalURL // Return original if not HTTP/HTTPS
        }
        // Ensure no double-scheming if already a custom scheme URL
        if originalURL.scheme == customScheme {
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

    // MARK: - MP4 Preloading
    public func initiatePreload(for originalURL: URL, preloadByteCount: Int64) {
        accessQueue.async { [weak self] in
            guard let self = self else { return }

            // 1. Check metadata: If fully downloaded, or if enough bytes are already downloaded, no need to preload.
            if let metadata = self.loadMetadata(for: originalURL) {
                if metadata.isFullyDownloaded {
                    // print("ℹ️ MP4 Preload: \(originalURL.lastPathComponent) already fully downloaded.")
                    return
                }
                // Check if the requested preloadByteCount is already covered
                var downloadedLengthForPreload: Int64 = 0
                for range in metadata.downloadedRanges {
                    if range.location == 0 { // We are interested in initial chunk for preload
                        downloadedLengthForPreload = max(downloadedLengthForPreload, Int64(NSMaxRange(range)))
                    }
                }
                if downloadedLengthForPreload >= preloadByteCount {
                    // print("ℹ️ MP4 Preload: \(originalURL.lastPathComponent) already has \(downloadedLengthForPreload) bytes, satisfying preload request for \(preloadByteCount).")
                    return
                }
            }

            // 2. Get or create VideoDataOperation
            let operation: VideoDataOperation
            if let existingOperation = self.activeOperations[originalURL] {
                operation = existingOperation
                // print("ℹ️ MP4 Preload: Using existing operation for \(originalURL.lastPathComponent).")
            } else {
                operation = VideoDataOperation(originalURL: originalURL, cacheManager: self)
                self.activeOperations[originalURL] = operation
                // print("ℹ️ MP4 Preload: Created new operation for \(originalURL.lastPathComponent).")
            }

            // 3. Instruct the operation to start preloading
            // print("ℹ️ MP4 Preload: Instructing operation to preload \(preloadByteCount) bytes for \(originalURL.lastPathComponent).")
            operation.startPreload(requestedByteCount: preloadByteCount)
        }
    }
    
    // MARK: - Internal Cache Logic (called by VideoDataOperation)
    func operation(_ operation: VideoDataOperation, didReceiveResponse response: URLResponse) {
        accessQueue.async { [weak self] in
            guard let self = self, let httpResponse = response as? HTTPURLResponse, let opOriginalURL = operation.originalURLFromOperation else { return } // Use URL from operation
            
            var totalLength: Int64 = 0
            if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String {
                if let totalStr = contentRange.components(separatedBy: "/").last, let total = Int64(totalStr) {
                    totalLength = total
                }
            }
            if totalLength == 0 { // Fallback if Content-Range is not present or not formatted as expected
                totalLength = httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : (response.expectedContentLength > 0 ? response.expectedContentLength : 0)
            }
            
            let mimeType = response.mimeType ?? "application/octet-stream"
            
            var metadata = self.loadMetadata(for: opOriginalURL)
            if metadata == nil {
                let fileName = self.cacheFileName(for: opOriginalURL)
                metadata = VideoCacheItemMetadata(originalURL: opOriginalURL, totalLength: totalLength, mimeType: mimeType, downloadedRanges: [], lastAccessDate: Date(), localFileName: fileName)
            } else {
                if metadata!.totalLength == 0 && totalLength > 0 { metadata!.totalLength = totalLength }
                 // Only update mimeType if it was generic and now we have a specific one
                if metadata!.mimeType == "application/octet-stream" && mimeType != "application/octet-stream" {
                    metadata!.mimeType = mimeType
                }
                metadata!.lastAccessDate = Date()
            }
            self.saveMetadata(metadata!)
            
            let acceptRanges = httpResponse.allHeaderFields["Accept-Ranges"] as? String
            operation.updateContentInformation(totalLength: totalLength, mimeType: mimeType, isByteRangeAccessSupported: acceptRanges?.lowercased() == "bytes")
        }
    }
    
    func operation(_ operation: VideoDataOperation, didReceiveData data: Data, atOffset offset: Int64) {
        accessQueue.async { [weak self] in
            guard let self = self, let opOriginalURL = operation.originalURLFromOperation, var metadata = self.loadMetadata(for: opOriginalURL) else { return }
            
            let filePath = self.cacheDirectory.appendingPathComponent(metadata.localFileName)
            do {
                let fileHandle: FileHandle
                if !FileManager.default.fileExists(atPath: filePath.path) {
                    FileManager.default.createFile(atPath: filePath.path, contents: nil, attributes: nil)
                }
                fileHandle = try FileHandle(forWritingTo: filePath)
                
                fileHandle.seek(toFileOffset: UInt64(offset))
                fileHandle.write(data)
                fileHandle.closeFile()
                
                let receivedRange = NSRange(location: Int(offset), length: data.count)
                metadata.downloadedRanges = self.mergeRanges(metadata.downloadedRanges, withNewRange: receivedRange)
                metadata.lastAccessDate = Date()
                self.saveMetadata(metadata)
                
                operation.processPendingRequests() // Process any player requests waiting for this data
                
            } catch {
                print("❌ Error writing to cache file \(filePath.lastPathComponent): \(error)")
                operation.failPendingRequests(with: error) // Fail player requests
            }
        }
    }
    
    func operationDidComplete(_ operation: VideoDataOperation, error: Error?) {
        accessQueue.async { [weak self] in
            guard let self = self, let opOriginalURL = operation.originalURLFromOperation else { return }
            if error == nil {
                if var metadata = self.loadMetadata(for: opOriginalURL) {
                    metadata.lastAccessDate = Date()
                    self.saveMetadata(metadata)
                    // print("✅ Operation for \(opOriginalURL.lastPathComponent) completed successfully. Fully downloaded: \(metadata.isFullyDownloaded)")
                }
            } else {
                // print("🔴 Operation for \(opOriginalURL.lastPathComponent) completed with error: \(error!.localizedDescription)")
            }
            
            // Only remove operation if it's not handling any more player requests and preload is done or failed
            if operation.isNoLongerNeeded() {
                 self.activeOperations.removeValue(forKey: opOriginalURL)
                 // print("🗑️ Removed operation for \(opOriginalURL.lastPathComponent). Active ops: \(self.activeOperations.count)")
            }

            if error == nil { // If successful, might have increased cache size
                self.cleanupCache()
            }
        }
    }
    
    // MARK: - Cache File & Metadata Management
    internal func cacheFileName(for url: URL) -> String {
        let unsafeChars = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let safePathComponent = url.lastPathComponent.components(separatedBy: unsafeChars).joined(separator: "_")
        let hash = url.absoluteString.data(using: .utf8)!.sha256().hexEncodedString().prefix(16)
        return "\(hash)_\(safePathComponent).mp4" // Assuming mp4, though could be other types
    }
    
    private func metadataFilePath(for originalURL: URL) -> URL {
        let fileName = cacheFileName(for: originalURL) + ".meta"
        return metadataDirectory.appendingPathComponent(fileName)
    }
    
    internal func loadMetadata(for originalURL: URL) -> VideoCacheItemMetadata? {
        let filePath = metadataFilePath(for: originalURL)
        guard FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              let metadata = try? JSONDecoder().decode(VideoCacheItemMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }
    
    internal func saveMetadata(_ metadata: VideoCacheItemMetadata) {
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
    
    private func mergeRanges(_ ranges: [NSRange], withNewRange newRange: NSRange) -> [NSRange] {
        var allRanges = ranges + [newRange]
        allRanges.removeAll { $0.length == 0 }
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
    
    internal func tryFulfillFromCache(loadingRequest: AVAssetResourceLoadingRequest, for originalURL: URL) -> Bool {
        guard let metadata = loadMetadata(for: originalURL), metadata.totalLength > 0 else { return false }
        
        if let infoRequest = loadingRequest.contentInformationRequest {
            if infoRequest.contentType == nil { // Only set if not already set
                if let typeIdentifier = UTType(mimeType: metadata.mimeType)?.identifier {
                    infoRequest.contentType = typeIdentifier
                } else {
                    infoRequest.contentType = UTType.data.identifier // Fallback
                }
            }
            if infoRequest.contentLength == 0 { infoRequest.contentLength = metadata.totalLength }
            infoRequest.isByteRangeAccessSupported = true // Assume true if we are caching ranges
        }
        
        guard let dataRequest = loadingRequest.dataRequest else {
             // This might be just an info request, which is fine.
             // If infoRequest was populated, we can consider it "fulfilled" in terms of info.
             if loadingRequest.contentInformationRequest != nil && !loadingRequest.isFinished {
                 // It's possible the player only wanted contentInformation at this stage.
                 // If all info is provided, we might not need to finishLoading() yet,
                 // as it might expect data requests later.
             }
            return false // No data request to fulfill from cache.
        }
        
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = dataRequest.requestedLength
        var currentOffsetInRequest = dataRequest.currentOffset // This is where the player expects data to start from for *this* respond call
        let requestedEnd = requestedOffset + Int64(requestedLength)
        var fulfilledAllRequestedData = false
        
        do {
            let fileHandle = try FileHandle(forReadingFrom: dataFilePath(for: metadata))
            defer { fileHandle.closeFile() }
            
            // Iterate through cached ranges to find data for the current request
            for cachedRange in mergeRanges(metadata.downloadedRanges, withNewRange: NSRange()) { // Ensure ranges are merged
                let rangeStartInCache = Int64(cachedRange.location)
                let rangeEndInCache = Int64(cachedRange.location + cachedRange.length)

                // Calculate the intersection of the current dataRequest's *remaining* need and this cachedRange
                let effectiveReadOffset = max(currentOffsetInRequest, rangeStartInCache)
                let effectiveReadEnd = min(requestedEnd, rangeEndInCache)
                
                if effectiveReadOffset < effectiveReadEnd {
                    let lengthToProvide = Int(effectiveReadEnd - effectiveReadOffset)
                    if lengthToProvide > 0 {
                        fileHandle.seek(toFileOffset: UInt64(effectiveReadOffset))
                        let data = fileHandle.readData(ofLength: lengthToProvide)
                        dataRequest.respond(with: data)
                        currentOffsetInRequest += Int64(data.count) // Advance based on data provided
                        if currentOffsetInRequest >= requestedEnd {
                            fulfilledAllRequestedData = true
                            break // Current dataRequest is fully satisfied
                        }
                    }
                }
            }
            
            if fulfilledAllRequestedData {
                if !loadingRequest.isFinished { loadingRequest.finishLoading() }
                // Update last access date on the main accessQueue
                self.accessQueue.async { [weak self] in
                    if var updatedMetadata = self?.loadMetadata(for: originalURL) {
                        updatedMetadata.lastAccessDate = Date()
                        self?.saveMetadata(updatedMetadata)
                    }
                }
                return true // This specific loadingRequest is fully handled from cache.
            }
            
            // If it's a request for all data to end and we have it fully downloaded
            if dataRequest.requestsAllDataToEndOfResource && metadata.isFullyDownloaded && currentOffsetInRequest >= metadata.totalLength {
                 if !loadingRequest.isFinished { loadingRequest.finishLoading() }
                 return true
            }

        } catch {
            print("❌ Error reading from cache for \(originalURL.lastPathComponent): \(error)")
            if !loadingRequest.isFinished { loadingRequest.finishLoading(with: error) }
            return true // Error occurred, consider it "handled" by failing.
        }
        return false // Not fully fulfilled from cache, network operation will continue/start.
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
            // print("ℹ️ Cache size is \(ByteCountFormatter.string(fromByteCount: currentCacheSize, countStyle: .file)). No cleanup needed.")
            return
        }
        
        print("🧹 Cache size (\(ByteCountFormatter.string(fromByteCount: currentCacheSize, countStyle: .file))) exceeds limit. Cleaning up...")
        
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
                    } else {
                        if FileManager.default.fileExists(atPath: metadataFileURL.path) {
                             try FileManager.default.removeItem(at: metadataFileURL)
                        }
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
            
            // Cancel and remove all active operations first
            let urlsToInvalidate = Array(self.activeOperations.keys)
            for url in urlsToInvalidate {
                if let operation = self.activeOperations.removeValue(forKey: url) {
                    operation.invalidateAndCancelSession()
                }
            }
            // Give a brief moment for sessions to fully invalidate before deleting files.
            // This is a simple approach; more robust would be to use completion handlers from invalidateAndCancelSession.
            self.accessQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { DispatchQueue.main.async{ completion?() }; return }
                do {
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
}
