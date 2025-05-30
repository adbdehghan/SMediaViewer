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
        URL(string: "https://static.euronews.com/articles/stories/08/36/19/56/1366x768_cmsv2_e0200b40-a0ec-5ac3-95bb-a18283d80ec9-8361956.jpg")!,
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!,
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!,
        URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!,
    ]

    @State private var visibleURL: URL?

     var body: some View {
         NavigationView {
             ScrollView {
                 LazyVStack(spacing: 20) { // LazyVStack is crucial for performance
                     ForEach(mediaURLs, id: \.self) { url in
                         // Pass a binding that resolves to true only if this is the visible URL
                         let isPlaying = Binding<Bool>(
                             get: { self.visibleURL == url },
                             set: { _ in }
                         )
                         
                         CachingMediaView(url: url, isPlaying: isPlaying)
                             .aspectRatio(10/10, contentMode: .fit)
                             .clipShape(RoundedRectangle(cornerRadius: 12))
                             .onAppear {
                                 // When this view appears, set it as the one that should be playing.
                                 self.visibleURL = url
                             }
                             .onDisappear {
                                 // If this view disappears and is still the "visible" one,
                                 // clear the state so nothing plays.
                                 if self.visibleURL == url {
                                     self.visibleURL = nil
                                 }
                             }
                     }
                 }
                 .padding()
             }
             .navigationTitle("Visible Playback Feed")
         }
     }
}

#Preview {
    ContentView()
}
