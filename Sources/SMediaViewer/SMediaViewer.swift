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
    
    private func setupVideo(for url: URL) {
        let isHLSStream = isHLS(url: url)
        let videoAssetURL: URL
        var usingResourceLoader = false
        
        if isHLSStream {
            if let localHLSURL = HLSAssetManager.shared.getLocalAssetURL(for: url) {
                videoAssetURL = localHLSURL
                // print("ℹ️ MediaView: Using PRELOADED HLS: \(url.lastPathComponent) from \(localHLSURL.path)")
            } else {
                videoAssetURL = url // Stream directly
                // print("ℹ️ MediaView: Streaming HLS directly: \(url.lastPathComponent)")
            }
            // For HLS (preloaded or direct stream), we generally DO NOT use the custom resource loader.
            // AVPlayer handles HLS manifests and segment loading.
            usingResourceLoader = false
        } else { // MP4 or other direct video file
            guard let customSchemeURL = VideoCacheManager.shared.assetURL(for: url) else {
                print("❌ MediaView: Could not get custom scheme URL for MP4: \(url.lastPathComponent)")
                displayErrorIcon()
                return
            }
            videoAssetURL = customSchemeURL
            usingResourceLoader = true // Use resource loader for MP4 caching
            // print("ℹ️ MediaView: Using VideoCacheManager (MP4 via custom scheme): \(url.lastPathComponent)")
        }
        
        let asset = AVURLAsset(url: videoAssetURL)
        if usingResourceLoader {
            asset.resourceLoader.setDelegate(VideoCacheManager.shared, queue: resourceLoaderDelegateQueue)
        }
        
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: KVO.playerItemStatusContext)
        
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        var playerLooper: AVPlayerLooper? = nil
        if !isHLSStream { // Looping typically makes more sense for short MP4s, less for HLS streams/VOD
            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        }
        
        imageView.isHidden = true
        if playerLayer == nil {
            playerLayer = AVPlayerLayer(player: queuePlayer)
            playerLayer!.videoGravity = .resizeAspectFill
            layer.insertSublayer(playerLayer!, at: 0)
        } else { playerLayer?.player = queuePlayer }
        playerLayer!.frame = bounds; playerLayer!.isHidden = false
        
        queuePlayer.volume = 0
        currentState = .video(url: url, player: queuePlayer, item: playerItem, looper: playerLooper, isHLS: isHLSStream)
    }
    
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
