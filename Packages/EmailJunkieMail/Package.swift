// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EmailJunkieMail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EmailJunkieMail", targets: ["EmailJunkieMail"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.2.0")
    ],
    targets: [
        .target(
            name: "EmailJunkieMail",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOIMAP", package: "swift-nio-imap")
            ]
        ),
        .testTarget(
            name: "EmailJunkieMailTests",
            dependencies: [
                "EmailJunkieMail",
                .product(name: "NIOEmbedded", package: "swift-nio")
            ]
        )
    ]
)
