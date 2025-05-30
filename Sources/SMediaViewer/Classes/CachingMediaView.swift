//
//  CachingMediaView.swift
//  SMediaViewer
//
//  Created by Adib.
//

import SwiftUI
import UIKit

public struct CachingMediaView: UIViewRepresentable {
    public let url: URL
    @Binding public var isPlaying: Bool

    public init(url: URL, isPlaying: Binding<Bool>) {
        self.url = url
        self._isPlaying = isPlaying
    }

    public func makeUIView(context: Context) -> MediaView {
        return MediaView()
    }

    public func updateUIView(_ uiView: MediaView, context: Context) {        
        // Use the new `currentURL` public computed property to prevent redundant reloads.
        if uiView.currentURL != url {
            uiView.configure(with: url)
        }
        
        // Play or pause based on the binding's value
        if isPlaying {
            uiView.play()
        } else {
            uiView.pause()
        }
    }

    public static func dismantleUIView(_ uiView: MediaView, coordinator: ()) {
        uiView.reset()
    }
}
