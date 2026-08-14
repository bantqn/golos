// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Golos",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Golos", targets: ["Golos"])
    ],
    targets: [
        // Тонкая C-обёртка над whisper.cpp: заголовки подкладываются
        // симлинками из Vendor/whisper.cpp скриптом build.sh
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Golos",
            dependencies: ["CWhisper"],
            path: "Sources/Golos",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "GolosTests",
            dependencies: ["Golos"],
            path: "Tests/GolosTests"
        )
    ]
)
