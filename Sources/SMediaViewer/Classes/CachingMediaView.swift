//
//  CachingMediaView.swift
//  SMediaViewer
//
//  Created by Adib.
//

import SwiftUI
import UIKit

/// A SwiftUI view that wraps the caching `MediaView` for easy integration.
public struct CachingMediaView: UIViewRepresentable {
    /// The URL of the media to display.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func makeUIView(context: Context) -> MediaView {
        // Create the underlying MediaView instance.
        return MediaView()
    }

    public func updateUIView(_ uiView: MediaView, context: Context) {
        // Update the view with the new URL, but only if it has changed.
        // This prevents redundant reloads when the view updates for other reasons.
        if uiView.currentOriginalURL != url {
            uiView.configure(with: url)
        }
    }

    public static func dismantleUIView(_ uiView: MediaView, coordinator: ()) {
        // Called when the view is removed from the hierarchy.
        // This is the ideal place to trigger cleanup.
        uiView.reset()
    }
}
