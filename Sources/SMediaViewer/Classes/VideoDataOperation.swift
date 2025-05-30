//
//  VideoDataOperation.swift
//  SMediaViewer
//
//  Created by Adib.
//

import AVFoundation
import UniformTypeIdentifiers  // For UTType

final class VideoDataOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked
    Sendable
{
    let originalURL: URL
    private weak var cacheManager: VideoCacheManager?
    private var session: URLSession!
    private var task: URLSessionDataTask?

    private var pendingRequests: Set<AVAssetResourceLoadingRequest> = []
    private let operationQueue = DispatchQueue(
        label: "com.yourcompany.videodataoperation.internalqueue")

    private var currentResponse: URLResponse?
    private var currentDataOffset: Int64 = 0

    init(originalURL: URL, cacheManager: VideoCacheManager) {
        self.originalURL = originalURL
        self.cacheManager = cacheManager
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .responsiveAV
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)  // Callbacks on internal session queue
        print("📼 VideoDataOperation created for \(originalURL.lastPathComponent)")
    }

    func add(loadingRequest: AVAssetResourceLoadingRequest) {
        operationQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingRequests.insert(loadingRequest)
            self.startOrResumeDownloadIfNeeded()

            if let response = self.currentResponse,
                let httpResponse = response as? HTTPURLResponse,
                let manager = self.cacheManager,  // Safely unwrap weak reference
                let metadata = manager.loadMetadata(for: self.originalURL)
            {
                self.updateContentInformationForRequest(
                    loadingRequest,
                    totalLength: metadata.totalLength,
                    mimeType: metadata.mimeType,
                    isByteRangeAccessSupported: httpResponse.allHeaderFields["Accept-Ranges"]
                        as? String == "bytes")
            }
        }
    }

    func cancel(loadingRequest: AVAssetResourceLoadingRequest) {
        operationQueue.async { [weak self] in
            self?.pendingRequests.remove(loadingRequest)
        }
    }

    func updateContentInformation(
        totalLength: Int64, mimeType: String, isByteRangeAccessSupported: Bool
    ) {
        operationQueue.async { [weak self] in
            self?.pendingRequests.forEach { request in
                self?.updateContentInformationForRequest(
                    request,
                    totalLength: totalLength,
                    mimeType: mimeType,
                    isByteRangeAccessSupported: isByteRangeAccessSupported)
            }
        }
    }

    private func updateContentInformationForRequest(
        _ loadingRequest: AVAssetResourceLoadingRequest, totalLength: Int64, mimeType: String,
        isByteRangeAccessSupported: Bool
    ) {
        if let infoRequest = loadingRequest.contentInformationRequest,
            infoRequest.contentType == nil
        {
            if let type = UTType(mimeType: mimeType) {
                infoRequest.contentType = type.identifier
            } else {
                infoRequest.contentType = nil
                print(
                    "⚠️ Warning: Could not create UTType for MIME type: '\(mimeType)'. ContentType will be nil."
                )
            }
            infoRequest.contentLength = totalLength
            infoRequest.isByteRangeAccessSupported = isByteRangeAccessSupported
        }
    }

    func processPendingRequests() {
        operationQueue.async { [weak self] in
            guard let self = self, let strongCacheManager = self.cacheManager else { return }
            var stillPending = Set<AVAssetResourceLoadingRequest>()
            for request in self.pendingRequests where !request.isFinished {
                if strongCacheManager.tryFulfillFromCache(
                    loadingRequest: request, for: self.originalURL)
                {
                    // Fulfilled and finished by cacheManager
                } else {
                    stillPending.insert(request)
                }
            }
            self.pendingRequests = stillPending
        }
    }

    private func startOrResumeDownloadIfNeeded() {  // Must be called on operationQueue
        guard task == nil || task?.state == .suspended || task?.state == .canceling else {
            return
        }

        guard let strongCacheManager = self.cacheManager else { return }  // Ensure cacheManager is available

        let metadata = strongCacheManager.loadMetadata(for: originalURL)
        var fromOffset: Int64 = 0
        if let meta = metadata, !meta.downloadedRanges.isEmpty {
            let sortedRanges = meta.downloadedRanges.sorted { $0.location < $1.location }
            if let lastRange = sortedRanges.last {  // Ensure there is a last range
                fromOffset = Int64(NSMaxRange(lastRange))
            }
        }

        if let totalLength = metadata?.totalLength, totalLength > 0, fromOffset >= totalLength {
            if metadata?.isFullyDownloaded == true {
                print(
                    "ℹ️ \(originalURL.lastPathComponent): Already fully downloaded. Metadata is up to date."
                )
                self.task?.cancel()  // Ensure no redundant task
                self.task = nil
                strongCacheManager.operationDidComplete(self, error: nil)  // Notify completion
                return
            } else {
                print(
                    "⚠️ \(originalURL.lastPathComponent): Offset \(fromOffset) >= totalLength \(totalLength), but not marked fully downloaded. Check metadata/download logic."
                )
                // Potentially attempt to re-verify or redownload missing pieces if a more complex logic was in place.
                // For this sequential download, this indicates a potential issue or end of download.
            }
        }

        var request = URLRequest(
            url: self.originalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if fromOffset > 0 || metadata?.totalLength ?? 0 > 0 {  // Only add range header if not starting from scratch or if totalLength known
            let rangeHeader = "bytes=\(fromOffset)-"
            request.addValue(rangeHeader, forHTTPHeaderField: "Range")
            print(
                "▶️ Resuming download for \(originalURL.lastPathComponent) from offset \(fromOffset)"
            )
        } else {
            print("▶️ Starting download for \(originalURL.lastPathComponent) from offset 0")
        }

        self.currentDataOffset = fromOffset
        self.task = session.dataTask(with: request)
        self.task?.resume()
    }

    func failPendingRequests(with error: Error) {
        operationQueue.async { [weak self] in
            self?.pendingRequests.forEach { request in
                if !request.isFinished { request.finishLoading(with: error) }
            }
            self?.pendingRequests.removeAll()
        }
    }

    func invalidateAndCancelSession() {
        operationQueue.async { [weak self] in
            guard let self = self else { return }
            self.task?.cancel()
            self.task = nil
            // session.invalidateAndCancel() will call didCompleteWithError with a cancel error
            // let the delegate method handle the final notification to cacheManager
            self.session.invalidateAndCancel()
        }
    }

    // MARK: - URLSessionDataDelegate
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let strongCacheManager = self.cacheManager else {
            completionHandler(.cancel)
            return
        }
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            let error = NSError(
                domain: "VideoDataOperation",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid HTTP response: \( (response as? HTTPURLResponse)?.statusCode ?? -1 ) for \(response.url?.absoluteString ?? "N/A")"
                ])
            print("❌ \(error.localizedDescription)")
            failPendingRequests(with: error)
            strongCacheManager.operationDidComplete(self, error: error)
            completionHandler(.cancel)
            return
        }

        operationQueue.async { [weak self] in  // Ensure state modification is on operationQueue
            guard let self = self else { return }
            self.currentResponse = response

            if httpResponse.statusCode == 206,  // Partial Content
                let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String,
                let range = contentRange.components(separatedBy: CharacterSet(charactersIn: " /-"))
                    .dropFirst().first,
                let startByte = Int64(range)
            {
                self.currentDataOffset = startByte
            } else if httpResponse.statusCode == 200 {  // Full content, server might have ignored range
                self.currentDataOffset = 0  // Data starts from the beginning
            }
            // Else, currentDataOffset remains as requested fromOffset

            strongCacheManager.operation(self, didReceiveResponse: response)
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let strongCacheManager = self.cacheManager else { return }
        // No need to dispatch to operationQueue here for currentDataOffset modification if it's only accessed
        // by this delegate method and then passed to cacheManager, which will use its own queue.
        // However, if currentDataOffset was read by other methods on operationQueue, it should be synchronized.
        // For simplicity here, assume this callback sequence is safe for currentDataOffset.
        strongCacheManager.operation(self, didReceiveData: data, atOffset: self.currentDataOffset)
        self.currentDataOffset += Int64(data.count)
    }

    // MARK: - URLSessionTaskDelegate
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        guard let strongCacheManager = self.cacheManager else { return }
        let finalError = error

        operationQueue.async { [weak self] in  // Process completion on operation queue
            guard let self = self else { return }

            if let nsError = error as NSError?,
                nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            {
                print("ℹ️ Task explicitly cancelled for \(self.originalURL.lastPathComponent)")
                // Pending requests are already failed if invalidateAndCancelSession was called.
                // If it's another form of cancellation, they might need explicit failing.
            } else if let finalError = finalError {
                print(
                    "❌ Task completed with error for \(self.originalURL.lastPathComponent): \(finalError.localizedDescription)"
                )
                self.failPendingRequests(with: finalError)
            } else {
                print("✅ Task completed successfully for \(self.originalURL.lastPathComponent)")
                self.processPendingRequests()  // Process any remaining requests with fully downloaded data
            }

            if task === self.task { self.task = nil }
            strongCacheManager.operationDidComplete(self, error: finalError)
        }
    }
}
