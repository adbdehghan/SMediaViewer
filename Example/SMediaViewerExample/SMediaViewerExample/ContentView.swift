//
//  ContentView.swift
//  SMediaViewerExample
//
//  Created by Adib Dehghan on 5/29/25.
//  Updated for TikTok/Instagram Reels-like experience with playback fix
//

import SwiftUI
import SMediaViewer // Your library for CachingMediaView
import UniformTypeIdentifiers // For UTType in VideoPlayerView if needed for future enhancements

// MediaItem struct remains the same
struct MediaItem: Identifiable {
    let id: URL // The URL itself is the Identifiable ID
    let username: String
    let videoURL: URL // Explicitly naming for clarity, same as id in this case
    var isHLS: Bool {
        videoURL.pathExtension.lowercased() == "m3u8" || videoURL.scheme?.contains("m3u8") == true
    }
}

// VideoFeedViewModel remains largely the same
class VideoFeedViewModel: ObservableObject {
    @Published var isPlaying: Bool = true
    @Published var likedVideos: Set<URL> = []

    func prepareInitialState(initialVideoURL: URL?) {
        isPlaying = true
    }

    func togglePlay() {
        isPlaying.toggle()
    }

    func toggleLike(for videoURL: URL) {
        if likedVideos.contains(videoURL) {
            likedVideos.remove(videoURL)
        } else {
            likedVideos.insert(videoURL)
        }
    }
}

struct ContentView: View {
    // Updated list of 30 media items with a mix of HLS and MP4
    let mediaItems: [MediaItem] = [
        // HLS Streams (15)
        MediaItem(id: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!, username: "apple_bipbop_ts", videoURL: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")!),
        MediaItem(id: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!, username: "mux_test_x36", videoURL: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!),
        MediaItem(id: URL(string: "https://d2zihajmogu5jn.cloudfront.net/bipbop-advanced/bipbop_16x9_variant.m3u8")!, username: "cloudfront_bipbop_var", videoURL: URL(string: "https://d2zihajmogu5jn.cloudfront.net/bipbop-advanced/bipbop_16x9_variant.m3u8")!),
        MediaItem(id: URL(string: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8")!, username: "tears_steel_hls_unified", videoURL: URL(string: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8")!),
        MediaItem(id: URL(string: "https://cdn.jwplayer.com/manifests/pZxWPRg4.m3u8")!, username: "jwplayer_manifest_1", videoURL: URL(string: "https://cdn.jwplayer.com/manifests/pZxWPRg4.m3u8")!),
        MediaItem(id: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!, username: "apple_bipbop_fmp4", videoURL: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")!),
        MediaItem(id: URL(string: "https://bitdash-a.akamaihd.net/content/MI201109210084_1/m3u8s/f08e80da-bf1d-4e3d-8899-f0f6155f6efa.m3u8")!, username: "bitdash_sintel_hls", videoURL: URL(string: "https://bitdash-a.akamaihd.net/content/MI201109210084_1/m3u8s/f08e80da-bf1d-4e3d-8899-f0f6155f6efa.m3u8")!),
        MediaItem(id: URL(string: "https://test-streams.mux.dev/pts_shift/master.m3u8")!, username: "mux_pts_shift", videoURL: URL(string: "https://test-streams.mux.dev/pts_shift/master.m3u8")!),    
        MediaItem(id: URL(string: "https://bitmovin-a.akamaihd.net/content/dataset/multi-codec/hevc/stream_fmp4.m3u8")!, username: "bitmovin_hevc_fmp4", videoURL: URL(string: "https://bitmovin-a.akamaihd.net/content/dataset/multi-codec/hevc/stream_fmp4.m3u8")!),

        // MP4 Videos (15)
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!, username: "bunny_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!, username: "elephants_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!, username: "blazes_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4")!, username: "escapes_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!, username: "sintel_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!, username: "fun_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!, username: "joyrides_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4")!, username: "meltdowns_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerMeltdowns.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackNavigation.mp4")!, username: "subaru_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/SubaruOutbackNavigation.mp4")!),
        MediaItem(id: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!, username: "tears_steel_mp4_google", videoURL: URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!),
        MediaItem(id: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4")!, username: "test_videos_bunny_1mb", videoURL: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4")!),
        MediaItem(id: URL(string: "https://test-videos.co.uk/vids/sintel/mp4/av1/360/Sintel_360_10s_1MB.mp4")!, username: "test_videos_sintel_av1", videoURL: URL(string: "https://test-videos.co.uk/vids/sintel/mp4/av1/360/Sintel_360_10s_1MB.mp4")!),
        MediaItem(id: URL(string: "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4")!, username: "learning_container_sample", videoURL: URL(string: "https://www.learningcontainer.com/wp-content/uploads/2020/05/sample-mp4-file.mp4")!),
        MediaItem(id: URL(string: "https://filesamples.com/samples/video/mp4/sample_1280x720.mp4")!, username: "filesamples_720p", videoURL: URL(string: "https://filesamples.com/samples/video/mp4/sample_1280x720.mp4")!),
        MediaItem(id: URL(string: "https://sample-videos.com/video123/mp4/720/big_buck_bunny_720p_1mb.mp4")!, username: "sample_videos_bunny_1mb", videoURL: URL(string: "https://sample-videos.com/video123/mp4/720/big_buck_bunny_720p_1mb.mp4")!),
    ]

    @StateObject private var viewModel = VideoFeedViewModel()
    @State private var currentVisibleItemID: URL?
    
    private var currentIndex: Int? {
        if let visibleID = currentVisibleItemID {
            return mediaItems.firstIndex(where: { $0.id == visibleID })
        }
        return nil
    }

    private let preloadAheadCount = 3
    private let mp4PreloadByteCount: Int64 = 5 * 1024 * 1024


    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(mediaItems) { item in
                        VideoPlayerView(
                            mediaItem: item,
                            isPlaying: Binding(
                                get: { currentVisibleItemID == item.id && viewModel.isPlaying },
                                set: { newIsPlayingStateForThisCell in
                                    if currentVisibleItemID == item.id {
                                        viewModel.isPlaying = newIsPlayingStateForThisCell
                                    }
                                }
                            ),
                            isLiked: viewModel.likedVideos.contains(item.id)
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .background(Color.black)
                        .clipped()
                        .id(item.id)
                        .onAppear {
                            // print("🎞️ VideoPlayerView for \(item.id.lastPathComponent) appeared.")
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .ignoresSafeArea()
            .scrollTargetBehavior(.paging)
            .ifAvailable(iOS: 17.0) { view in
                view.scrollPosition(id: $currentVisibleItemID)
            }
            .onChange(of: currentVisibleItemID) { oldValue, newValue in
                guard let newVisibleID = newValue, let newIndex = mediaItems.firstIndex(where: { $0.id == newVisibleID }) else {
                    return
                }
                let oldIndex = oldValue != nil ? mediaItems.firstIndex(where: { $0.id == oldValue }) : nil

                if newIndex != oldIndex {
                    if !viewModel.isPlaying {
                        viewModel.isPlaying = true
                    }
                    triggerPreload(aroundItemWithID: newVisibleID)
                }
            }
            .gesture(
                TapGesture(count: 2)
                    .onEnded {
                        if let currentItemID = currentVisibleItemID {
                            viewModel.toggleLike(for: currentItemID)
                        }
                    }
                    .simultaneously(with: TapGesture()
                        .onEnded {
                            viewModel.togglePlay()
                        }
                    )
            )
            .onAppear {
                if !mediaItems.isEmpty, let firstItem = mediaItems.first {
                    currentVisibleItemID = firstItem.id
                    viewModel.prepareInitialState(initialVideoURL: firstItem.id)
                }
            }
        }
        .ignoresSafeArea()
        .statusBar(hidden: true)
    }

    private func triggerPreload(aroundItemWithID centerItemID: URL) {
        guard let centerIndex = mediaItems.firstIndex(where: { $0.id == centerItemID }) else {
            return
        }

        var hlsUrlsToPreload: [URL] = []
        var mp4UrlsToPreload: [URL] = []

        for i in 1...preloadAheadCount {
            let nextIndex = centerIndex + i
            if nextIndex < mediaItems.count {
                let itemToPreload = mediaItems[nextIndex]
                if itemToPreload.isHLS {
                    hlsUrlsToPreload.append(itemToPreload.videoURL)
                } else {
                    mp4UrlsToPreload.append(itemToPreload.videoURL)
                }
            }
        }
        
        let uniqueHlsUrlsToPreload = Array(Set(hlsUrlsToPreload))
        if !uniqueHlsUrlsToPreload.isEmpty {
            HLSAssetManager.shared.updatePreloadQueue(nextPotentialHLSURLs: uniqueHlsUrlsToPreload)
        }

        let uniqueMp4UrlsToPreload = Array(Set(mp4UrlsToPreload))
        if !uniqueMp4UrlsToPreload.isEmpty {
            uniqueMp4UrlsToPreload.forEach { mp4Url in
                VideoCacheManager.shared.initiatePreload(for: mp4Url, preloadByteCount: mp4PreloadByteCount)
            }
        }
    }
}

struct VideoPlayerView: View {
    let mediaItem: MediaItem
    @Binding var isPlaying: Bool
    let isLiked: Bool

    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            CachingMediaView(url: mediaItem.videoURL, isPlaying: $isPlaying)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(contentMode: .fill) // Corrected: Was ContentMode.fill
                .clipped()

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("@\(mediaItem.username)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 1, y: 1)
                        
                        if progress > 0 && progress < 1 && isPlaying {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.3)).frame(height: 3)
                                    Capsule().fill(Color.white).frame(width: geo.size.width * CGFloat(progress), height: 3)
                                }
                            }
                            .frame(height: 3)
                            .frame(width: 120)
                            .padding(.bottom, 5)
                        }
                    }
                    .padding(.leading, 16)

                    Spacer()

                    VStack(spacing: 24) {
                        SideBarButton(systemImageName: isLiked ? "heart.fill" : "heart", iconColor: isLiked ? .red : .white, text: "1.2M") {}
                        SideBarButton(systemImageName: "message.fill", text: "30K") {}
                        SideBarButton(systemImageName: "arrowshape.turn.up.right.fill", text: "Share") {}
                    }
                    .padding(.trailing, 10)
                }
                .padding(.bottom, (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom ?? 0 > 0 ? 30 : 70)
            }
        }
    }
}

struct SideBarButton: View {
    let systemImageName: String
    var iconColor: Color = .white
    let text: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImageName)
                    .font(.system(size: 28))
                    .foregroundColor(iconColor)
                if let text = text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 1)
        }
    }
}

extension View {
    @ViewBuilder
    func ifAvailable<Content: View>(iOS version: Double, modifier: (Self) -> Content) -> some View {
        if #available(iOS 17.0, *) {
            modifier(self)
        } else {
            self
        }
    }
}

//#Preview {
//    ContentView()
//}
