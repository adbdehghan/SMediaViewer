import AVFoundation
import SDWebImage
import UIKit
import UniformTypeIdentifiers

class MediaView: UIView {
    private let imageView: UIImageView = {
          let iv = UIImageView()
          iv.contentMode = .scaleAspectFill
          iv.clipsToBounds = true
          iv.isHidden = true
          iv.backgroundColor = .secondarySystemBackground
          return iv
      }()

      private var player: AVPlayer?
      private var playerLayer: AVPlayerLayer?
      private var currentOriginalURL: URL?
      private var playerLooper: AVPlayerLooper?
      private var asset: AVURLAsset?

      private let resourceLoaderDelegateQueue = DispatchQueue(label: "com.yourcompany.mediaview.resourceloader.queue")

      override init(frame: CGRect) {
          super.init(frame: frame)
          setupSubviews()
      }

      required init?(coder: NSCoder) {
          super.init(coder: coder)
          setupSubviews()
      }

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

      override func layoutSubviews() {
          super.layoutSubviews()
          playerLayer?.frame = bounds
      }

      func configure(with url: URL) {
          reset()
          self.currentOriginalURL = url
          let pathExtension = url.pathExtension.lowercased()

          if ["mp4", "mov", "m4v"].contains(pathExtension) {
              imageView.isHidden = true
              playerLayer?.isHidden = false
              setupAdvancedVideoPlayer(for: url)
          } else if ["jpg", "jpeg", "png", "gif", "webp"].contains(pathExtension) {
              playerLayer?.isHidden = true
              imageView.isHidden = false
              imageView.sd_imageIndicator = SDWebImageActivityIndicator.gray
              imageView.sd_setImage(with: url,
                                    placeholderImage: UIImage(systemName: "photo"),
                                    options: [.retryFailed, .progressiveLoad, .decodeFirstFrameOnly],
                                    completed: nil)
          } else {
              imageView.isHidden = false
              playerLayer?.isHidden = true
              imageView.image = UIImage(systemName: "questionmark.diamond")
              print("⚠️ Unknown media type for URL: \(url.lastPathComponent)")
          }
      }

      private func setupAdvancedVideoPlayer(for originalVideoURL: URL) {
          cleanUpPlayer()

          guard let assetURLWithCustomScheme = VideoCacheManager.shared.assetURL(for: originalVideoURL) else {
              print("❌ Could not create custom scheme URL for video: \(originalVideoURL.lastPathComponent).")
              DispatchQueue.main.async { self.displayErrorIcon() }
              return
          }
          
          asset = AVURLAsset(url: assetURLWithCustomScheme)
          asset!.resourceLoader.setDelegate(VideoCacheManager.shared, queue: resourceLoaderDelegateQueue)

          let playerItem = AVPlayerItem(asset: asset!)
          playerItem.addObserver(self,
                                 forKeyPath: #keyPath(AVPlayerItem.status),
                                 options: [.old, .new],
                                 context: KVO.playerItemStatusContext)
          
          let queuePlayer = AVQueuePlayer(playerItem: playerItem)
          player = queuePlayer
          playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)

          playerLayer = AVPlayerLayer(player: player)
          playerLayer!.frame = bounds
          playerLayer!.videoGravity = .resizeAspectFill
          layer.insertSublayer(playerLayer!, at: 0)

          player?.volume = 0
          player?.play()
      }
      
      private func displayErrorIcon() {
          self.imageView.isHidden = false
          self.playerLayer?.isHidden = true
          self.imageView.image = UIImage(systemName: "xmark.octagon.fill")?.withRenderingMode(.alwaysTemplate)
          self.imageView.tintColor = .systemGray
          self.imageView.contentMode = .center
      }

      // `observeValue` signature remains nonisolated.
      override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
          guard context == KVO.playerItemStatusContext, keyPath == #keyPath(AVPlayerItem.status) else {
              super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
              return
          }

          // Extract Sendable data before dispatching.
          // NSNumber is Sendable.
          let newStatusNumber = change?[.newKey] as? NSNumber
          
          // ObjectIdentifier is Sendable. We use it to identify the object later.
          // Ensure `object` is an AnyObject before creating ObjectIdentifier.
          // KVO's `object` parameter is `Any?`, which could be a non-class type if KVO is used differently,
          // but for AVPlayerItem, it will be an AVPlayerItem (NSObject subclass).
          guard let observedAnyObject = object as AnyObject? else {
              // If object is nil or not an AnyObject, we can't get an ObjectIdentifier.
              // This case should ideally not happen for AVPlayerItem KVO.
              return
          }
          let observedObjectIdentifier = ObjectIdentifier(observedAnyObject)

          // Dispatch to the main actor using Task for modern concurrency.
          Task { @MainActor [weak self] in // Capture self weakly. newStatusNumber and observedObjectIdentifier are Sendable and captured by value.
              guard let self = self else { return }

              // On the MainActor:
              // 1. Verify that the KVO notification pertains to our *current* player item
              //    by comparing ObjectIdentifiers. This avoids acting on stale notifications
              //    for player items that might have been replaced.
              guard let currentPlayerItem = self.player?.currentItem, // Access self.player.currentItem on MainActor
                    ObjectIdentifier(currentPlayerItem) == observedObjectIdentifier else {
                  // The KVO notification is for an AVPlayerItem that is no longer
                  // the current item of our player, or the player/item is nil. Ignore it.
                  return
              }

              // 2. Now that we've confirmed it's our current item, we can safely use `currentPlayerItem`.
              let status: AVPlayerItem.Status
              if let statusNum = newStatusNumber {
                  status = AVPlayerItem.Status(rawValue: statusNum.intValue)!
              } else {
                  status = .unknown
              }
              
              switch status {
              case .readyToPlay:
                  print("📺 Player item ready to play for \(self.currentOriginalURL?.lastPathComponent ?? "N/A")")
              case .failed:
                  // Access `currentPlayerItem.error` safely on the MainActor.
                  let error = currentPlayerItem.error
                  print("❌ Player item failed for \(self.currentOriginalURL?.lastPathComponent ?? "N/A"). Error: \(error?.localizedDescription ?? "Unknown error")")
                  self.displayErrorIcon()
              case .unknown:
                  print("❔ Player item status unknown for \(self.currentOriginalURL?.lastPathComponent ?? "N/A")")
              @unknown default:
                  break
              }
          }
      }

      private func cleanUpPlayer() {
          player?.pause()
          if let currentItem = player?.currentItem, player != nil {
              currentItem.removeObserver(self,
                                         forKeyPath: #keyPath(AVPlayerItem.status),
                                         context: KVO.playerItemStatusContext)
          }
          
          player = nil
          playerLooper = nil
          playerLayer?.removeFromSuperlayer()
          playerLayer = nil
          
          asset?.resourceLoader.setDelegate(nil, queue: nil)
          asset = nil
      }

      func reset() {
          imageView.sd_cancelCurrentImageLoad()
          imageView.image = nil
          imageView.isHidden = true
          imageView.contentMode = .scaleAspectFill

          cleanUpPlayer()
          
          currentOriginalURL = nil
      }

      override func willMove(toWindow newWindow: UIWindow?) {
          super.willMove(toWindow: newWindow)
          if newWindow == nil {
              print("♻️ MediaView for \(currentOriginalURL?.lastPathComponent ?? "N/A") is being removed from window. Calling reset.")
              reset()
          }
      }

      deinit {
          print("🗑️ MediaView deinit sequence completed for URL: \(currentOriginalURL?.lastPathComponent ?? "N/A")")
      }
  }

