//
//  ContentView.swift
//  SMediaViewerExample
//
//  Created by Adib Dehghan on 5/29/25.
//

import SwiftUI
import SMediaViewer

struct ContentView: View {
    // A list of sample URLs (a mix of videos and images)
    let mediaURLs: [URL] = [
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
        URL(string: "https://picsum.photos/id/237/1280/720")!,
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!,
        URL(string: "https://picsum.photos/id/10/1280/720")!,
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!,
        URL(string: "https://picsum.photos/id/20/1280/720")!,
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!,
        URL(string: "https://picsum.photos/id/30/1280/720")!
    ]

    var body: some View {
        NavigationView {
            List {
                ForEach(mediaURLs, id: \.self) { url in
                    // Use your new SwiftUI-compatible view
                    CachingMediaView(url: url)
                        .aspectRatio(16/9, contentMode: .fit) // Set a frame or aspect ratio
                        .clipShape(RoundedRectangle(cornerRadius: 12)) // Add some styling
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            .listStyle(.plain)
            .navigationTitle("Caching Media Feed")
        }
    }
}

#Preview {
    ContentView()
}
