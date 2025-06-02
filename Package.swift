// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SMediaViewer",
    platforms: [
           .iOS(.v14),
           .macOS(.v10_15),
           .tvOS(.v13),           
       ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SMediaViewer",
            targets: ["SMediaViewer"]),
    ],
    dependencies: [
        // Add SDWebImage dependency
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", from: "5.19.0"), // Use the latest appropriate version
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "SMediaViewer",
            dependencies: [
                // Depend on the SDWebImage product
                .product(name: "SDWebImage", package: "SDWebImage"),
                .product(name: "OrderedCollections", package: "swift-collections")
            ]),
    ]
)
