//
//  ContentView.swift
//  SMediaViewerExample
//
//  Created by Adib Dehghan on 5/29/25.
//

import SwiftUI
import SMediaViewer // Your package
import OrderedCollections // For HLSAssetManager's queue
import HLSAssetManager

struct ContentView: View {
    // A list of sample URLs (a mix of videos and images)
    // For a Shorts-like experience, these should ideally be portrait aspect ratio videos.
    let mediaItems: [MediaItem] = [ // Using a struct for better data handling
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!), // Consider portrait HLS/MP4 for best Shorts feel
        MediaItem(id: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!),
        MediaItem(id: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!),
        // Add an image to test mixed content if desired
        // MediaItem(id: URL(string: "https://picsum.photos/id/237/1080/1920")!),
    ]

    // Tracks the currently selected (visible) media item's URL
    @State private var currentVisibleURL: URL?
    // Tracks the index of the currently visible item for preloading
    @State private var currentIndex: Int = 0

    // How many items ahead to preload for HLS
    private let preloadAheadCount = 2

    var body: some View {
        // TabView with page style for vertical scrolling like Shorts
        TabView(selection: $currentIndex) {
            ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                let isPlaying = Binding<Bool>(
                    get: { self.currentVisibleURL == item.id && mediaItems[currentIndex].id == item.id },
                    set: { _ in /* This binding is primarily read-only for CachingMediaView here */ }
                )

                CachingMediaView(url: item.id, isPlaying: isPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity) // Fullscreen
                    .background(Color.black) // Background for letter/pillar-boxing
                    .clipped() // Ensures content stays within bounds
                    .tag(index) // Tag for TabView selection
                    .ignoresSafeArea() // Make it truly fullscreen
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never)) // Vertical paging, no index dots
        .ignoresSafeArea()
        .onAppear {
            // Set initial visible URL and trigger initial preload
            if !mediaItems.isEmpty {
                self.currentIndex = 0 // Start at the first item
                self.currentVisibleURL = mediaItems[0].id
                triggerPreload(around: 0)
            }
        }
        .onChange(of: currentIndex) { newIndex in
            // When the active tab changes, update the visible URL and trigger preloading
            if newIndex >= 0 && newIndex < mediaItems.count {
                self.currentVisibleURL = mediaItems[newIndex].id
                triggerPreload(around: newIndex)
            }
        }
    }

    /// Triggers the HLS preloading logic based on the current visible index.
    private func triggerPreload(around index: Int) {
        var urlsToPreload: [URL] = []
        // Preload next items
        for i in 1...preloadAheadCount {
            let nextIndex = index + i
            if nextIndex < mediaItems.count {
                let item = mediaItems[nextIndex]
                // Only preload HLS videos
                if item.id.pathExtension.lowercased() == "m3u8" {
                    urlsToPreload.append(item.id)
                }
            }
        }
        
        // Optionally, preload previous items if desired
        // for i in 1...preloadAheadCount {
        //     let prevIndex = index - i
        //     if prevIndex >= 0 {
        //         let item = mediaItems[prevIndex]
        //         if item.id.pathExtension.lowercased() == "m3u8" {
        //             urlsToPreload.append(item.id) // HLSAssetManager uses OrderedSet, so duplicates are handled
        //         }
        //     }
        // }

        if !urlsToPreload.isEmpty {
            print("🎞️ Requesting HLS preload for: \(urlsToPreload.map { $0.lastPathComponent })")
            HLSAssetManager.shared.updatePreloadQueue(nextPotentialHLSURLs: urlsToPreload)
        }
    }
}

// Helper struct for items in the feed
struct MediaItem: Identifiable {
    let id: URL // Using URL as ID, assuming they are unique
    // You can add other properties like author, description, etc.
}

#Preview {
    ContentView()
}
