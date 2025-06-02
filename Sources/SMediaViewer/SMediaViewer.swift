import UIKit
import AVFoundation
import SDWebImage

public final class MediaView: UIView {
    // MARK: - State Machine
    private enum MediaState {
        case idle
        case image(url: URL)
        case video(url: URL, player: AVPlayer, item: AVPlayerItem, looper: AVPlayerLooper?, isHLS: Bool)
    }
    
    
    // MARK: - Properties
    private var currentState: MediaState = .idle
    private let resourceLoaderDelegateQueue = DispatchQueue(label: "com.yourcompany.mediaview.resourceloader.queue")
    public var currentURL: URL? {
        switch currentState {
        case .image(let url), .video(let url, _, _, _, _): return url
        case .idle: return nil
        }
    }
    private var timeObserverToken: Any? // For progress updates if needed later
    
    private lazy var imageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .secondarySystemBackground
        return iv
    }()
    
    private var playerLayer: AVPlayerLayer?
    
    // MARK: - Lifecycle
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }
    
    deinit {
        // Cleanup is handled by willMove(toWindow:), prepareForReuse, and dismantleUIView.
        // deinit remains empty of main-actor calls.
        print("🗑️ MediaView deinit sequence completed.")
    }
    
    // MARK: - Public API
    public func configure(with url: URL) {
        // print("🔄 MediaView configuring with URL: \(url.lastPathComponent)")
        reset() // Reset previous state before configuring new URL
        
        let pathExtension = url.pathExtension.lowercased()
        let scheme = url.scheme?.lowercased()
        
        if ["mp4", "mov", "m4v"].contains(pathExtension) || (scheme == VideoCacheManager.shared.customScheme && !isHLS(url: url)) {
            // print("📹 MediaView: Setting up as MP4/MOV video.")
            setupVideo(for: url)
        } else if isHLS(url: url) || (scheme == VideoCacheManager.shared.customScheme && isHLS(url: url) ) { // Check for HLS
            // print("📹 MediaView: Setting up as HLS video.")
            setupVideo(for: url)
        }
        else if ["jpg", "jpeg", "png", "gif", "webp"].contains(pathExtension) {
            // print("🖼️ MediaView: Setting up as Image.")
            setupImage(for: url)
        } else {
            print("⚠️ MediaView: Unknown media type for URL: \(url.lastPathComponent)")
            displayErrorIcon()
        }
    }
    
    
    public func reset() {
        switch currentState {
        case .video(_, let player, let item, _, _):
            player.pause()
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), context: KVO.playerItemStatusContext)
        case .image: imageView.sd_cancelCurrentImageLoad()
        case .idle: break
        }
        playerLayer?.removeFromSuperlayer(); playerLayer = nil
        imageView.image = nil; imageView.isHidden = true
        currentState = .idle
    }
    
    // MARK: - State Setup
    private func setupImage(for url: URL) {
        currentState = .image(url: url)
        imageView.isHidden = false
        playerLayer?.isHidden = true // Ensure player layer is hidden
        
        imageView.sd_imageIndicator = SDWebImageActivityIndicator.medium // or .large
        imageView.sd_setImage(with: url, placeholderImage: UIImage(systemName: "photo.fill"), options: [.retryFailed, .progressiveLoad]) { [weak self] (image, error, cacheType, url) in
            if error != nil {
                // print("❌ Error loading image \(url?.lastPathComponent ?? ""): \(error!.localizedDescription)")
                self?.displayErrorIcon()
            } else {
                // print("🖼️ Image loaded successfully: \(url?.lastPathComponent ?? "")")
            }
        }
    }
    
    private func isHLS(url: URL) -> Bool {
        // Check original URL if it's a custom scheme
        if let original = VideoCacheManager.shared.originalURL(from: url) {
            return original.pathExtension.lowercased() == "m3u8"
        }
        return url.pathExtension.lowercased() == "m3u8"
    }
    
    public func play() {
        if case .video(_, let player, _, _, _) = currentState {
            if player.timeControlStatus != .playing {
                // print("▶️ MediaView: Play command received for \(currentURL?.lastPathComponent ?? "N/A")")
                player.play()
            }
        }
    }
    
    public func pause() {
        if case .video(_, let player, _, _, _) = currentState {
            if player.timeControlStatus == .playing {
                // print("⏸️ MediaView: Pause command received for \(currentURL?.lastPathComponent ?? "N/A")")
                player.pause()
            }
        }
    }
    
    // MARK: - Asynchronous Video Setup
        private func setupVideo(for url: URL) {
            // Since setup is now async, we immediately update the state to reflect the intended URL,
            // preventing race conditions if user scrolls away quickly.
            // Although the player is not ready, we "claim" this URL.
            // The reset() call in configure() clears the old player.
            self.currentState = .video(url: url, player: AVQueuePlayer(), item: AVPlayerItem(url: url), looper: nil, isHLS: false) // Temporary placeholder state

            let isHLSStream = isHLS(url: url)
            var videoAssetURL: URL
            var usingResourceLoader = false

            if isHLSStream {
                    if let localHLSURL = HLSAssetManager.shared.getLocalAssetURL(for: url) {
                        // Check if the URL points to a .movpkg package
                        if localHLSURL.pathExtension.lowercased() == "movpkg" {
                            // Locate the .m3u8 file inside the .movpkg package
                            let fileManager = FileManager.default
                            guard let movpkgContents = try? fileManager.contentsOfDirectory(at: localHLSURL, includingPropertiesForKeys: nil, options: []) else {
                                print("Unable to access .movpkg contents")
                                displayErrorIcon()
                                return
                            }
                            
                            // Find the .m3u8 file
                            let m3u8URL = movpkgContents.first { $0.pathExtension.lowercased() == "m3u8" }
                            guard let playlistURL = m3u8URL else {
                                print("No .m3u8 file found in .movpkg package")
                                displayErrorIcon()
                                return
                            }
                            
                            videoAssetURL = playlistURL
                        } else {
                            videoAssetURL = localHLSURL
                        }
                    } else {
                        videoAssetURL = url
                    }
                    usingResourceLoader = false
            } else {
                guard let customSchemeURL = VideoCacheManager.shared.assetURL(for: url) else {
                    displayErrorIcon(); return
                }
                videoAssetURL = customSchemeURL
                usingResourceLoader = true
            }
               
            let asset = AVURLAsset(url: videoAssetURL)
            
            if usingResourceLoader {
                asset.resourceLoader.setDelegate(VideoCacheManager.shared, queue: resourceLoaderDelegateQueue)
            }
            
            // Asynchronously load the "playable" key to ensure the asset is valid before use.
            let requiredAssetKeys = ["playable", "duration"]
            asset.loadValuesAsynchronously(forKeys: requiredAssetKeys) { [weak self] in
                guard let self = self else { return }

                // Switch to the main thread to handle the results and update the UI
                DispatchQueue.main.async {
                    // Verify that the view hasn't been reconfigured for a different URL while we were loading.
                    guard case .video(let currentConfigURL, _, _, _, _) = self.currentState, currentConfigURL == url else {
                        print("ℹ️ Asset loaded for \(url.lastPathComponent), but view has been reconfigured. Aborting setup.")
                        return
                    }

                    var error: NSError? = nil
                    let status = asset.statusOfValue(forKey: "playable", error: &error)

                    switch status {
                    case .loaded:
                        // The asset is playable, we can now create the player item and the player.
                        self.finishVideoSetup(with: asset, for: url, isHLS: isHLSStream)

                    case .failed:
                        // The asset failed to load. This can happen if the local file is corrupt.
                        print("❌ Asset for \(url.lastPathComponent) is NOT PLAYABLE. Error: \(error?.localizedDescription ?? "Unknown error")")
                        self.displayErrorIcon()

                    case .cancelled:
                        // Loading was cancelled, likely because we called reset().
                        print("ℹ️ Asset loading was cancelled for \(url.lastPathComponent).")
                    
                    default: // .unknown, .loading
                        print("❔ Asset for \(url.lastPathComponent) has an unknown playable status.")
                        break
                    }
                }
            }
        }

        // This new helper function completes the setup on the main thread once the asset is confirmed to be playable.
        private func finishVideoSetup(with asset: AVAsset, for url: URL, isHLS: Bool) {
            let playerItem = AVPlayerItem(asset: asset)
            // Add KVO observer *after* confirming the asset is playable.
            playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: KVO.playerItemStatusContext)

            let queuePlayer = AVQueuePlayer(playerItem: playerItem)
            var playerLooper: AVPlayerLooper? = nil
            if !isHLS {
                playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
            }

            self.imageView.isHidden = true
            if self.playerLayer == nil {
                self.playerLayer = AVPlayerLayer(player: queuePlayer)
                self.playerLayer!.videoGravity = .resizeAspectFill
                self.layer.insertSublayer(self.playerLayer!, at: 0)
            } else {
                self.playerLayer?.player = queuePlayer
            }
            self.playerLayer!.frame = self.bounds
            self.playerLayer!.isHidden = false

            queuePlayer.volume = 0
            // Update the final state with the fully configured player components.
            self.currentState = .video(url: url, player: queuePlayer, item: playerItem, looper: playerLooper, isHLS: isHLS)
        }
    
//    private func setupVideo(for url: URL) {
//        let isHLSStream = isHLS(url: url)
//        let videoAssetURL: URL
//        var usingResourceLoader = false
//        
//        if isHLSStream {
//            if let localHLSURL = HLSAssetManager.shared.getLocalAssetURL(for: url) {
//                videoAssetURL = localHLSURL
//                // print("ℹ️ MediaView: Using PRELOADED HLS: \(url.lastPathComponent) from \(localHLSURL.path)")
//            } else {
//                videoAssetURL = url // Stream directly
//                // print("ℹ️ MediaView: Streaming HLS directly: \(url.lastPathComponent)")
//            }
//            // For HLS (preloaded or direct stream), we generally DO NOT use the custom resource loader.
//            // AVPlayer handles HLS manifests and segment loading.
//            usingResourceLoader = false
//        } else { // MP4 or other direct video file
//            guard let customSchemeURL = VideoCacheManager.shared.assetURL(for: url) else {
//                print("❌ MediaView: Could not get custom scheme URL for MP4: \(url.lastPathComponent)")
//                displayErrorIcon()
//                return
//            }
//            videoAssetURL = customSchemeURL
//            usingResourceLoader = true // Use resource loader for MP4 caching
//            // print("ℹ️ MediaView: Using VideoCacheManager (MP4 via custom scheme): \(url.lastPathComponent)")
//        }
//        
//        let asset = AVURLAsset(url: videoAssetURL)
//        if usingResourceLoader {
//            asset.resourceLoader.setDelegate(VideoCacheManager.shared, queue: resourceLoaderDelegateQueue)
//        }
//        
//        let playerItem = AVPlayerItem(asset: asset)
//        playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: KVO.playerItemStatusContext)
//        
//        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
//        var playerLooper: AVPlayerLooper? = nil
//        if !isHLSStream { // Looping typically makes more sense for short MP4s, less for HLS streams/VOD
//            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
//        }
//        
//        imageView.isHidden = true
//        if playerLayer == nil {
//            playerLayer = AVPlayerLayer(player: queuePlayer)
//            playerLayer!.videoGravity = .resizeAspectFill
//            layer.insertSublayer(playerLayer!, at: 0)
//        } else { playerLayer?.player = queuePlayer }
//        playerLayer!.frame = bounds; playerLayer!.isHidden = false
//        
//        queuePlayer.volume = 0
//        currentState = .video(url: url, player: queuePlayer, item: playerItem, looper: playerLooper, isHLS: isHLSStream)
//    }
    
    // MARK: - KVO
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        // 1. Perform the minimal, nonisolated check first.
        guard context == KVO.playerItemStatusContext, keyPath == #keyPath(AVPlayerItem.status) else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        
        // 2. Extract Sendable values to pass to the main actor.
        let newStatusNumber = change?[.newKey] as? NSNumber
        guard let observedAnyObject = object as AnyObject? else { return }
        let observedObjectIdentifier = ObjectIdentifier(observedAnyObject)
        
        // 3. Dispatch all further logic to the main actor.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // 4. Perform ALL state-dependent checks and work inside the MainActor context.
            guard case .video(_, _, let currentItem, _, _) = self.currentState,
                  ObjectIdentifier(currentItem) == observedObjectIdentifier else {
                // This KVO notification is for an old player item we are no longer tracking. Ignore it.
                return
            }
            
            let status: AVPlayerItem.Status
            if let statusNum = newStatusNumber {
                status = AVPlayerItem.Status(rawValue: statusNum.intValue)!
            } else {
                status = .unknown
            }
            
            switch status {
            case .readyToPlay:
                print("📺 Player item ready to play.")
                self.playerLayer?.isHidden = false
            case .failed:
                print("❌ Player item failed: \(currentItem.error?.localizedDescription ?? "Unknown error")")
                self.displayErrorIcon()
            case .unknown:
                print("❔ Player item status is unknown.")
            @unknown default:
                break
            }
        }
    }
    
    // MARK: - Helpers
    private func setupSubviews() {
        addSubview(imageView)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor), imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    
    private func displayErrorIcon() {
        self.imageView.isHidden = false; self.playerLayer?.isHidden = true
        self.imageView.image = UIImage(systemName: "xmark.octagon.fill")?.withRenderingMode(.alwaysTemplate)
        self.imageView.tintColor = .systemGray; self.imageView.contentMode = .center
    }
    
    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            reset()
        }
    }
}
