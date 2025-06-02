//
//  VideoDataOperation.swift
//  SMediaViewer
//
//  Created by Adib.
//

//
//  VideoDataOperation.swift
//  SMediaViewer
//
//  Created by Adib.
//

import AVFoundation
import UniformTypeIdentifiers  // For UTType

final class VideoDataOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    // Public getter for originalURL to be accessible by VideoCacheManager for logging/metadata
    public var originalURLFromOperation: URL? { self.originalURL }
    private let originalURL: URL

    private weak var cacheManager: VideoCacheManager?
    private var session: URLSession!
    private var dataTask: URLSessionDataTask? // Renamed from 'task' for clarity

    private var pendingRequests: Set<AVAssetResourceLoadingRequest> = []
    private let operationQueue = DispatchQueue(label: "com.yourcompany.videodataoperation.internalqueue", qos: .userInitiated)

    private var currentResponse: URLResponse?
    private var currentDataOffset: Int64 = 0 // Tracks the offset for the current download segment

    // Preloading state
    private var isPreloading: Bool = false
    private var preloadRequestedByteCount: Int64 = 0
    private var preloadTask: URLSessionDataTask?


    init(originalURL: URL, cacheManager: VideoCacheManager) {
        self.originalURL = originalURL
        self.cacheManager = cacheManager
        super.init()
        // Use a shared URLSessionConfiguration or create a new one
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .responsiveAV // Good for AV content
        // Callbacks will be handled on the operationQueue for session delegate methods
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue())
        // print("📼 VideoDataOperation created for \(originalURL.lastPathComponent)")
    }

    func add(loadingRequest: AVAssetResourceLoadingRequest) {
        operationQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingRequests.insert(loadingRequest)
            
            // If a preload task is active and this request falls within its scope,
            // it will be fulfilled as data arrives. Otherwise, start a new data task if needed.
            if self.preloadTask == nil || self.preloadTask?.state != .running {
                 self.startOrResumeDataTaskIfNeeded(for: loadingRequest)
            }


            // Try to fulfill info request immediately if possible
            if let response = self.currentResponse,
               let httpResponse = response as? HTTPURLResponse,
               let manager = self.cacheManager,
               let metadata = manager.loadMetadata(for: self.originalURL) {
                self.updateContentInformationForRequest(loadingRequest,
                                                        totalLength: metadata.totalLength,
                                                        mimeType: metadata.mimeType,
                                                        isByteRangeAccessSupported: httpResponse.allHeaderFields["Accept-Ranges"] as? String == "bytes")
            }
            // Actual data fulfillment will happen as data arrives or from cache via processPendingRequests
        }
    }

    func cancel(loadingRequest: AVAssetResourceLoadingRequest) {
        operationQueue.async { [weak self] in
            self?.pendingRequests.remove(loadingRequest)
            // If no more pending requests and not preloading, consider cancelling the dataTask
            if self?.pendingRequests.isEmpty == true && self?.isPreloading == false {
                // self?.dataTask?.cancel() // Be careful not to cancel if preload is active or will resume
            }
        }
    }
    
    func startPreload(requestedByteCount: Int64) {
        operationQueue.async { [weak self] in
            guard let self = self else { return }

            if self.isPreloading && self.preloadRequestedByteCount >= requestedByteCount && self.preloadTask?.state == .running {
                // print("ℹ️ Preload already active and sufficient for \(self.originalURL.lastPathComponent)")
                return
            }
            
            // Cancel any existing regular data task if we are starting a preload
            // Or, if a preload task exists but for fewer bytes, cancel and restart.
            if self.dataTask?.state == .running {
                // print("ℹ️ Cancelling existing dataTask to start preload for \(self.originalURL.lastPathComponent)")
                self.dataTask?.cancel()
                self.dataTask = nil // Nullify it so a new one can be made for preload
            }
            if self.preloadTask?.state == .running && self.preloadRequestedByteCount < requestedByteCount {
                // print("ℹ️ Cancelling existing preloadTask to restart with larger byte count for \(self.originalURL.lastPathComponent)")
                self.preloadTask?.cancel() // Cancel existing preload if new request is for more bytes
                self.preloadTask = nil
            }


            self.isPreloading = true
            self.preloadRequestedByteCount = requestedByteCount
            self.currentDataOffset = 0 // Preload starts from the beginning

            // If metadata exists, check if we already have the preloadable chunk
            if let metadata = self.cacheManager?.loadMetadata(for: self.originalURL) {
                var initialChunkDownloaded = false
                for range in metadata.downloadedRanges {
                    if range.location == 0 && NSMaxRange(range) >= Int(min(metadata.totalLength > 0 ? metadata.totalLength : Int64.max, requestedByteCount)) {
                        initialChunkDownloaded = true
                        break
                    }
                }
                if initialChunkDownloaded {
                    // print("ℹ️ Preload: Initial chunk for \(self.originalURL.lastPathComponent) already cached up to \(requestedByteCount) bytes.")
                    self.isPreloading = false // Preload considered complete if data is there
                    self.cacheManager?.operationDidComplete(self, error: nil) // Notify manager
                    return
                }
                // Adjust currentDataOffset if some part of the initial chunk is already downloaded
                for range in metadata.downloadedRanges.sorted(by: { $0.location < $1.location }) {
                    if range.location == self.currentDataOffset {
                        self.currentDataOffset = Int64(NSMaxRange(range))
                    } else if range.location > self.currentDataOffset {
                        break // Gap found, download from currentDataOffset
                    }
                }

                if metadata.totalLength > 0 && self.currentDataOffset >= min(metadata.totalLength, requestedByteCount) {
                     // print("ℹ️ Preload: Sufficient initial data already present for \(self.originalURL.lastPathComponent), offset \(self.currentDataOffset) >= requested \(requestedByteCount) or total \(metadata.totalLength).")
                     self.isPreloading = false
                     self.cacheManager?.operationDidComplete(self, error: nil)
                     return
                }
            }
            
            if self.preloadTask?.state == .running { // If a preload task is already running for enough bytes
                 if self.isPreloading && self.preloadRequestedByteCount >= requestedByteCount { return }
            }


            var request = URLRequest(url: self.originalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            // For preload, request from currentDataOffset up to preloadRequestedByteCount
            // If totalLength is known and less than preloadRequestedByteCount, request up to totalLength
            var toOffset = self.currentDataOffset + self.preloadRequestedByteCount - 1
            if let metadata = self.cacheManager?.loadMetadata(for: self.originalURL), metadata.totalLength > 0 {
                toOffset = min(toOffset, metadata.totalLength - 1)
            }
            
            if self.currentDataOffset <= toOffset { // Ensure there's something to request
                let rangeHeader = "bytes=\(self.currentDataOffset)-\(toOffset)"
                request.addValue(rangeHeader, forHTTPHeaderField: "Range")
                // print("▶️ Starting PRELOAD for \(self.originalURL.lastPathComponent), Range: \(rangeHeader)")
                self.preloadTask = self.session.dataTask(with: request)
                self.preloadTask?.resume()
            } else {
                // print("ℹ️ Preload for \(self.originalURL.lastPathComponent): No data to request for preload range (offset \(self.currentDataOffset) > toOffset \(toOffset)). Might be fully cached or an issue.")
                self.isPreloading = false // Nothing to preload
                self.cacheManager?.operationDidComplete(self, error: nil) // Notify completion
            }
        }
    }


    private func startOrResumeDataTaskIfNeeded(for loadingRequest: AVAssetResourceLoadingRequest? = nil) { // Must be called on operationQueue
        guard dataTask == nil || dataTask?.state == .suspended || dataTask?.state == .canceling else {
            // print("ℹ️ Data task for \(originalURL.lastPathComponent) already running or completed.")
            return
        }
        // If a preload task is running, let it continue. Don't start a regular data task.
        if preloadTask?.state == .running {
            // print("ℹ️ Preload task running for \(originalURL.lastPathComponent). Regular data task deferred.")
            return
        }

        guard let strongCacheManager = self.cacheManager else { return }

        let metadata = strongCacheManager.loadMetadata(for: originalURL)
        var fromOffset: Int64 = 0

        if let request = loadingRequest?.dataRequest {
            fromOffset = request.currentOffset // Start from where the player is asking
        } else if let meta = metadata, !meta.downloadedRanges.isEmpty {
            // Fallback: if no specific request, try to resume from the end of the last downloaded range
            // This part might be too aggressive if not driven by a specific request.
            // For now, let's assume a loadingRequest will define the starting point for non-preload tasks.
            // If called without a loadingRequest, it implies a general "ensure data is flowing" which is tricky.
            // Let's primarily rely on loadingRequest to define the range for dataTask.
            // If no loadingRequest, this method might not start a task unless it's a resume scenario.
            let sortedRanges = meta.downloadedRanges.sorted { $0.location < $1.location }
            if let lastContinuousRangeEnd = sortedRanges.lastContinuousEndOffset() {
                 fromOffset = lastContinuousRangeEnd
            }
        }
        
        // If metadata indicates full download, and no specific loadingRequest is asking for data, then we are done.
        if metadata?.isFullyDownloaded == true && loadingRequest == nil {
            // print("ℹ️ \(originalURL.lastPathComponent): Already fully downloaded (metadata). No specific request.")
            strongCacheManager.operationDidComplete(self, error: nil)
            return
        }
        // If a specific loading request is already fulfilled by cache, it won't reach here due to tryFulfillFromCache
        
        self.currentDataOffset = fromOffset // This is where the current dataTask will attempt to fetch from

        var request = URLRequest(url: self.originalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        // For dataTask, the range is typically open-ended or up to totalLength if known.
        // AVPlayer usually requests specific byte ranges.
        let rangeHeader: String
        if let totalLength = metadata?.totalLength, totalLength > 0 {
            if fromOffset >= totalLength { // Already downloaded everything or request is beyond EOD
                // print("ℹ️ \(originalURL.lastPathComponent): Request from offset \(fromOffset) is at or beyond total length \(totalLength).")
                // If there's a loadingRequest, it should be completed (likely with 0 bytes or error if out of bounds)
                loadingRequest?.finishLoading() // Assuming it's an empty request past EOF
                strongCacheManager.operationDidComplete(self, error: nil) // Consider this operation complete for this request
                return
            }
            rangeHeader = "bytes=\(fromOffset)-\(totalLength - 1)"
        } else {
            rangeHeader = "bytes=\(fromOffset)-" // Request data from offset to end
        }
        request.addValue(rangeHeader, forHTTPHeaderField: "Range")
        // print("▶️ Starting/Resuming DATA TASK for \(originalURL.lastPathComponent), Range: \(rangeHeader)")

        self.dataTask = session.dataTask(with: request)
        self.dataTask?.resume()
    }
    
    func updateContentInformation(totalLength: Int64, mimeType: String, isByteRangeAccessSupported: Bool) {
        operationQueue.async { [weak self] in
            self?.currentResponse = HTTPURLResponse(url: self!.originalURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "\(totalLength)", "Accept-Ranges": isByteRangeAccessSupported ? "bytes" : "none"]) // Simulate a response for info
            self?.pendingRequests.forEach { request in
                self?.updateContentInformationForRequest(request, totalLength: totalLength, mimeType: mimeType, isByteRangeAccessSupported: isByteRangeAccessSupported)
            }
        }
    }

    private func updateContentInformationForRequest(_ loadingRequest: AVAssetResourceLoadingRequest, totalLength: Int64, mimeType: String, isByteRangeAccessSupported: Bool) {
        if let infoRequest = loadingRequest.contentInformationRequest, infoRequest.contentType == nil {
            if let typeIdentifier = UTType(mimeType: mimeType)?.identifier {
                infoRequest.contentType = typeIdentifier
            } else {
                infoRequest.contentType = UTType.data.identifier // Fallback
            }
            infoRequest.contentLength = totalLength
            infoRequest.isByteRangeAccessSupported = isByteRangeAccessSupported
        }
    }

    func processPendingRequests() {
        operationQueue.async { [weak self] in
            guard let self = self, let strongCacheManager = self.cacheManager else { return }
            var stillPending = Set<AVAssetResourceLoadingRequest>()
            for request in self.pendingRequests where !request.isFinished && !request.isCancelled {
                if strongCacheManager.tryFulfillFromCache(loadingRequest: request, for: self.originalURL) {
                    // Fulfilled and finished by cacheManager
                } else {
                    stillPending.insert(request)
                }
            }
            self.pendingRequests = stillPending
            // If no more pending requests and not preloading, consider cleanup.
            if self.pendingRequests.isEmpty && !self.isPreloading {
                // print("ℹ️ No more pending requests for \(self.originalURL.lastPathComponent) and not preloading.")
                // self.dataTask?.cancel() // Optional: aggressive cancellation
                // self.cacheManager?.operationDidComplete(self, error: nil) // Notify manager if truly done
            }
        }
    }

    func failPendingRequests(with error: Error) {
        operationQueue.async { [weak self] in
            self?.pendingRequests.forEach { request in
                if !request.isFinished && !request.isCancelled { request.finishLoading(with: error) }
            }
            self?.pendingRequests.removeAll()
        }
    }

    func invalidateAndCancelSession() {
        operationQueue.async { [weak self] in
            guard let self = self else { return }
            // print("ℹ️ Invalidating and cancelling session for \(self.originalURL.lastPathComponent)")
            self.preloadTask?.cancel()
            self.preloadTask = nil
            self.dataTask?.cancel()
            self.dataTask = nil
            self.session.invalidateAndCancel() // This will trigger didCompleteWithError with a cancel error
            // Do not call cacheManager.operationDidComplete here, let the delegate method handle it.
        }
    }
    
    func isNoLongerNeeded() -> Bool { // Call on operationQueue
        return pendingRequests.isEmpty && !isPreloading && (dataTask == nil || dataTask?.state != .running) && (preloadTask == nil || preloadTask?.state != .running)
    }

    // MARK: - URLSessionDataDelegate
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let strongCacheManager = self.cacheManager else {
            completionHandler(.cancel); return
        }
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let error = NSError(domain: "VideoDataOperation", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response: \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(response.url?.absoluteString ?? "N/A")"])
            // print("❌ \(error.localizedDescription)")
            operationQueue.async { [weak self] in // Ensure state changes and delegate calls are on operationQueue
                self?.failPendingRequests(with: error)
                strongCacheManager.operationDidComplete(self!, error: error) // self is captured strongly here
            }
            completionHandler(.cancel)
            return
        }

        operationQueue.async { [weak self] in
            guard let self = self else { completionHandler(.cancel); return }
            self.currentResponse = response // Store the response

            // Update currentDataOffset based on Content-Range if present (for both preload and data tasks)
            if httpResponse.statusCode == 206, // Partial Content
               let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String,
               let rangeStartStr = contentRange.components(separatedBy: CharacterSet(charactersIn: " bytes-/")).first(where: { !$0.isEmpty }),
               let startByte = Int64(rangeStartStr) {
                self.currentDataOffset = startByte
            } else if httpResponse.statusCode == 200 { // Full content, server might have ignored range or it's not a range request
                 if dataTask === self.preloadTask || (dataTask === self.dataTask && self.pendingRequests.first?.dataRequest?.currentOffset == 0) {
                    self.currentDataOffset = 0 // Data starts from the beginning for this task
                 }
            }
            // Else, currentDataOffset was set before making the request, e.g. for resuming.

            strongCacheManager.operation(self, didReceiveResponse: response)
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let strongCacheManager = self.cacheManager else { return }
        
        let receivedDataOffset = self.currentDataOffset // Capture offset before it's incremented
        strongCacheManager.operation(self, didReceiveData: data, atOffset: receivedDataOffset)

        operationQueue.async { [weak self] in // Increment on operation queue
             self?.currentDataOffset += Int64(data.count)
        }
    }

    // MARK: - URLSessionTaskDelegate
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let strongCacheManager = self.cacheManager else { return }
        
        operationQueue.async { [weak self] in
            guard let self = self else { return }

            let isPreloadCompletion = (task === self.preloadTask)
            if isPreloadCompletion {
                self.isPreloading = false // Preload attempt finished
                self.preloadTask = nil
            } else if task === self.dataTask {
                self.dataTask = nil
            }


            if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                // print("ℹ️ Task explicitly cancelled for \(self.originalURL.lastPathComponent). Was preload: \(isPreloadCompletion)")
                // If it was a user-initiated cancel (invalidateAndCancelSession), pending requests are already cleared.
                // If it was an internal cancel (e.g. switching from dataTask to preloadTask), handle accordingly.
            } else if let completionError = error {
                // print("❌ Task completed with error for \(self.originalURL.lastPathComponent): \(completionError.localizedDescription). Was preload: \(isPreloadCompletion)")
                self.failPendingRequests(with: completionError)
            } else { // No error, task completed successfully
                // print("✅ Task completed successfully for \(self.originalURL.lastPathComponent). Was preload: \(isPreloadCompletion)")
                // If it was a preload task, check if requested bytes were downloaded.
                if isPreloadCompletion {
                    if let metadata = strongCacheManager.loadMetadata(for: self.originalURL) {
                        var initialChunkDownloaded = false
                        for range in metadata.downloadedRanges {
                             if range.location == 0 && NSMaxRange(range) >= Int(min(metadata.totalLength > 0 ? metadata.totalLength : Int64.max, self.preloadRequestedByteCount)) {
                                initialChunkDownloaded = true
                                break
                            }
                        }
                        // print("ℹ️ Preload for \(self.originalURL.lastPathComponent) completed. Sufficient initial chunk downloaded: \(initialChunkDownloaded)")
                    }
                }
                self.processPendingRequests() // Process any player requests with the newly downloaded data
            }
            
            // Notify cache manager about the operation's overall completion status
            // This might be called multiple times if both preload and data tasks run for the same operation object.
            // The cacheManager's operationDidComplete should be idempotent or handle this.
            strongCacheManager.operationDidComplete(self, error: error)
        }
    }
}


// Helper extension for Array<NSRange>
extension Array where Element == NSRange {
    func lastContinuousEndOffset() -> Int64? {
        guard !self.isEmpty else { return nil }
        let sorted = self.sorted { $0.location < $1.location }
        var currentEnd: Int64 = 0
        if sorted.first!.location == 0 {
            currentEnd = Int64(NSMaxRange(sorted.first!))
            for i in 1..<sorted.count {
                if sorted[i].location == Int(currentEnd) {
                    currentEnd = Int64(NSMaxRange(sorted[i]))
                } else if sorted[i].location < Int(currentEnd) { // Overlap
                    currentEnd = Swift.max(currentEnd, Int64(NSMaxRange(sorted[i])))
                }
                else {
                    break // Discontinuity
                }
            }
            return currentEnd
        }
        return nil // No continuous block from offset 0
    }
}
