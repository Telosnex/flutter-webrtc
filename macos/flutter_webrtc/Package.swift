// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_webrtc",
    platforms: [
        .macOS("10.15")
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
            url: "https://github.com/Telosnex/libwebrtc/releases/download/libwebrtc.m144.7559.09-telosnex.05/WebRTC.xcframework.zip",
            checksum: "dcacf11d424c8aa7bfc3ecd4754157ae957890f92ea4f542e6ebf3369ee1293c"
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
                // Ends up weak-linked (LC_LOAD_WEAK_DYLIB) like the podspec's weak_frameworks:
                // all ScreenCaptureKit usage is @available-guarded and the 10.15 platform
                // minimum above predates the framework, so clang weak-imports its symbols
                // and no explicit weak_framework flag is needed. This holds as long as
                // ScreenCaptureKit APIs are only used behind availability checks.
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio")
            ]
        )
    ]
)
