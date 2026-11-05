// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Airloom",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "Airloom", targets: ["Airloom"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "Airloom", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources", exclude: ["ScreenSaver"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("ServiceManagement"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
