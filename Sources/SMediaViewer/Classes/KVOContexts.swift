//
//  KVOContexts.swift
//  SMediaViewer
//
//  Created by Adib.
//

import Foundation

enum KVO { // Renamed for clarity, use any namespace you prefer
    // 1. Define a private static dummy variable. Its only purpose is to provide a unique memory address.
    nonisolated(unsafe) private static var playerItemStatusContextDummy: UInt8 = 0

    // 2. Create a static 'let' constant pointer that holds the address of the dummy variable.
    // This 'playerItemStatusContext' pointer is immutable and its value (the address) is stable.
    // This is what you'll use for KVO.
    nonisolated(unsafe) static let playerItemStatusContext: UnsafeMutableRawPointer = UnsafeMutableRawPointer(&playerItemStatusContextDummy)
}
