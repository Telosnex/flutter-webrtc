// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_webrtc",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(name: "flutter-webrtc", targets: ["flutter_webrtc"]),
        // Lets dependent plugins (e.g. livekit_client) import WebRTC without
        // declaring a second copy of the binary target.
        .library(name: "WebRTC", targets: ["WebRTC"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/Telosnex/libwebrtc/releases/download/libwebrtc.m144.7559.09-telosnex.10/WebRTC.xcframework.zip",
            checksum: "39b28f13d6db7fe70ed348ab0b3b4504fd7c4d92ee1968221fef9a1820dd404b"
        ),
        .target(
            name: "flutter_webrtc",
            dependencies: [
                "WebRTC",
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            cSettings: [
                .headerSearchPath("include/flutter_webrtc")
            ],
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        )
    ],
    cxxLanguageStandard: .cxx14
)
