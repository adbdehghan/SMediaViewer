//
//  VideoCacheItemMetadata.swift
//  SMediaViewer
//
//  Created by Adib.
//

import Foundation

import Foundation

struct VideoCacheItemMetadata: Codable {
    let originalURL: URL
    var totalLength: Int64
    var mimeType: String
    var downloadedRanges: [NSRange] // Should be kept sorted and merged
    var lastAccessDate: Date
    let localFileName: String

    var isFullyDownloaded: Bool {
        guard totalLength > 0 else { return false }
        var coveredLength: Int64 = 0
        // Ensure ranges are canonical (sorted and merged) before calculating
        for range in mergeOverlappingRanges(ranges: downloadedRanges) {
            coveredLength += Int64(range.length)
        }
        return coveredLength >= totalLength
    }
    
    // Helper to merge ranges for accurate length calculation
    // This should ideally be called whenever downloadedRanges is modified to keep it canonical.
    private func mergeOverlappingRanges(ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sortedRanges = ranges.sorted { $0.location < $1.location }
        
        var merged: [NSRange] = []
        var currentMerge = sortedRanges.first!
        
        for i in 1..<sortedRanges.count {
            let nextRange = sortedRanges[i]
            if NSMaxRange(currentMerge) >= nextRange.location { // Overlap or adjacent
                currentMerge.length = max(NSMaxRange(currentMerge), NSMaxRange(nextRange)) - currentMerge.location
            } else {
                merged.append(currentMerge)
                currentMerge = nextRange
            }
        }
        merged.append(currentMerge)
        return merged
    }
}
