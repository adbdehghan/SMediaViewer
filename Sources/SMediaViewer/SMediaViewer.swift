import UIKit
import AVFoundation
import SDWebImage

public final class MediaView: UIView {
    // MARK: - State Machine
    private enum MediaState {
        case idle
        case image(url: URL)
        case video(url: URL, player: AVPlayer, item: AVPlayerItem, looper: AVPlayerLooper)
    }
    
    // MARK: - Properties
    private var currentState: MediaState = .idle
    private let resourceLoaderDelegateQueue = DispatchQueue(label: "com.yourcompany.mediaview.resourceloader.queue")
    public var currentURL: URL? {
            switch currentState {
            case .image(let url), .video(let url, _, _, _):
                return url
            case .idle:
                return nil
            }
        }
    
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
         reset()

         let pathExtension = url.pathExtension.lowercased()

         if ["mp4", "mov", "m4v"].contains(pathExtension) {
             setupVideo(for: url)
         } else if ["jpg", "jpeg", "png", "gif", "webp"].contains(pathExtension) {
             setupImage(for: url)
         } else {
             print("⚠️ Unknown media type for URL: \(url.lastPathComponent)")
             displayErrorIcon()
         }
     }
    
    func reset() {
        switch currentState {
        case .video(_, let player, let item, _):
            player.pause()
            item.removeObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), context: KVO.playerItemStatusContext)
            print("✅ KVO observer cleanly removed for video.")
        case .image:
            imageView.sd_cancelCurrentImageLoad()
        case .idle:
            break
        }
        
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        
        imageView.image = nil
        imageView.isHidden = true
        
        currentState = .idle
    }
    
    // MARK: - State Setup
    private func setupImage(for url: URL) {
        currentState = .image(url: url)
        imageView.isHidden = false
        imageView.sd_imageIndicator = SDWebImageActivityIndicator.gray
        imageView.sd_setImage(with: url,
                              placeholderImage: UIImage(systemName: "photo"),
                              options: [.retryFailed, .progressiveLoad, .decodeFirstFrameOnly])
    }
    
    public func play() {
        // Play the video if the current state is a video
        if case .video(_, let player, _, _) = currentState {
            player.play()
        }
    }
    
    public func pause() {
        // Pause the video if the current state is a video
        if case .video(_, let player, _, _) = currentState {
            player.pause()
        }
    }
    
    private func setupVideo(for url: URL) {
        guard let assetURL = VideoCacheManager.shared.assetURL(for: url) else {
            print("❌ Could not create custom scheme URL for video.")
            displayErrorIcon()
            return
        }
        
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(VideoCacheManager.shared, queue: resourceLoaderDelegateQueue)
        
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.addObserver(self, forKeyPath: #keyPath(AVPlayerItem.status), options: [.old, .new], context: KVO.playerItemStatusContext)
        
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        
        let newPlayerLayer = AVPlayerLayer(player: queuePlayer)
        newPlayerLayer.frame = self.bounds
        newPlayerLayer.videoGravity = .resizeAspectFill
        self.layer.insertSublayer(newPlayerLayer, at: 0)
        self.playerLayer = newPlayerLayer
        
        queuePlayer.volume = 0
        
        
        currentState = .video(url: url, player: queuePlayer, item: playerItem, looper: playerLooper)
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
            guard case .video(_, _, let currentItem, _) = self.currentState,
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
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    
    private func displayErrorIcon() {
        self.imageView.isHidden = false
        self.playerLayer?.isHidden = true
        self.imageView.image = UIImage(systemName: "xmark.octagon.fill")?.withRenderingMode(.alwaysTemplate)
        self.imageView.tintColor = .systemGray
        self.imageView.contentMode = .center
    }
    
    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            reset()
        }
    }
}
