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

    public init(url: URL) {
        self.url = url
    }

    public func makeUIView(context: Context) -> MediaView {
        return MediaView()
    }

    public func updateUIView(_ uiView: MediaView, context: Context) {
        // Using the state enum means configure() already handles resetting,
        // so we don't need to check the URL here if we always call configure.
        uiView.configure(with: url)
    }

    // This is the crucial cleanup hook for SwiftUI.
    // It is called on the main actor when SwiftUI removes the view.
    public static func dismantleUIView(_ uiView: MediaView, coordinator: ()) {
        print("Dismantling MediaView for SwiftUI. Calling reset.")
        uiView.reset()
    }
}
