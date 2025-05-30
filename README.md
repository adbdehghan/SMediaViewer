# CachingMediaView

![Swift](https://img.shields.io/badge/Swift-5.7-orange.svg)
![Platform](https://img.shields.io/badge/Platform-iOS%2014%2B-blue.svg)
![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

A high-performance, concurrent, and caching media view for iOS, built in Swift. It can seamlessly display video or image content from a URL, automatically detecting the media type. It features an advanced caching layer for both images and videos, making it ideal for use in high-performance feeds like those in `UICollectionView` or SwiftUI `List`.

## Features

-   ✅ **Automatic Content Type Detection**: Simply provide a URL, and the view will determine whether to display an image or play a video.
-   🚀 **Advanced Video Caching**: Utilizes `AVAssetResourceLoaderDelegate` to cache video chunks as they are downloaded. This allows for progressive playback (playing while downloading) and serves content from the cache on subsequent requests, even enabling offline playback of cached videos.
-   🖼️ **Efficient Image Caching**: Leverages the robust and popular **SDWebImage** library for multi-layered image caching (memory and disk).
-   ⚡ **Concurrency-Safe**: Built with modern Swift Concurrency in mind, using actors and Sendable checks to prevent data races.
-   📱 **SwiftUI & UIKit Ready**: Can be used as a `UIView` subclass in UIKit or seamlessly integrated into SwiftUI projects via a `UIViewRepresentable` wrapper.
-   🔧 **Cache Management**: Provides a public API to clear the video cache when needed.

## Requirements

-   iOS 14.0+
-   Xcode 14.0+
-   Swift 5.7+

## Installation

You can add `CachingMediaView` to your project using Swift Package Manager.

1.  In Xcode, open your project and navigate to **File → Add Packages...**
2.  Paste the repository URL into the search bar:
    ```
    [https://github.com/YourUsername/CachingMediaView.git](https://github.com/YourUsername/CachingMediaView.git)
    ```
3.  Choose the `Up to Next Major Version` dependency rule and click **Add Package**.
4.  Select the `CachingMediaView` library and add it to your app's target.

SPM will automatically handle the dependency on `SDWebImage`.

## Usage

### SwiftUI (Recommended)

The package includes a `UIViewRepresentable` wrapper called `CachingMediaView`. This makes it incredibly easy to use in SwiftUI.

```swift
import SwiftUI
import CachingMediaView

struct ContentView: View {
    // A list of sample URLs (videos and images)
    let mediaURLs: [URL] = [
        URL(string: "[http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4](http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4)")!,
        URL(string: "[https://picsum.photos/id/237/800/600](https://picsum.photos/id/237/800/600)")!,
        URL(string: "[http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4](http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4)")!,
        URL(string: "[https://picsum.photos/id/10/800/600](https://picsum.photos/id/10/800/600)")!,
        URL(string: "[http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4](http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4)")!,
        URL(string: "[https://picsum.photos/id/20/800/600](https://picsum.photos/id/20/800/600)")!
    ]

    var body: some View {
        NavigationView {
            List(mediaURLs, id: \.self) { url in
                CachingMediaView(url: url)
                    .aspectRatio(16/9, contentMode: .fit) // Give it a frame or aspect ratio
                    .listRowInsets(EdgeInsets()) // Make it fill the row
            }
            .navigationTitle("Media Feed")
        }
    }
}
```

### UIKit

You can use the underlying `MediaView` (`UIView`) directly in your `UIViewController` or `UICollectionViewCell`.

```swift
import UIKit
import CachingMediaView

class MyMediaCell: UICollectionViewCell {
    static let identifier = "MyMediaCell"
    let mediaView = MediaView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        // Add constraints to pin mediaView to the edges of the cell's contentView
        NSLayoutConstraint.activate([
            mediaView.topAnchor.constraint(equalTo: contentView.topAnchor),
            mediaView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            mediaView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mediaView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with url: URL) {
        mediaView.configure(with: url)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        mediaView.reset()
    }
}
```

## Advanced Usage

### Clearing the Video Cache

You can manually clear the entire video cache if needed, for example, to free up disk space in your app's settings.

```swift
import CachingMediaView

VideoCacheManager.shared.clearAllCache {
    print("Video cache has been cleared.")
}
```

## License

This package is released under the MIT license. See [LICENSE](LICENSE) for details.
