// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISmartFramingCameraCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AISmartFramingCameraCore", targets: ["AISmartFramingCameraCore"])
    ],
    targets: [
        .target(
            name: "AISmartFramingCameraCore",
            path: "AISmartFramingCamera/Models"
        ),
        .testTarget(
            name: "AISmartFramingCameraCoreTests",
            dependencies: ["AISmartFramingCameraCore"],
            path: "Tests/AISmartFramingCameraCoreTests"
        )
    ]
)
