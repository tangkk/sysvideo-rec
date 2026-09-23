// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "SysVideoRecorder",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "sysvideo-rec", targets: ["SysVideoRecorder"])],
    targets: [
        .executableTarget(
            name: "SysVideoRecorder",
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        )
    ]
)
