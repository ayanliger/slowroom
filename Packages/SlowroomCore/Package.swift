// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlowroomCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "SlowroomCore", targets: ["SlowroomCore"])],
    dependencies: [
        .package(
            url: "https://github.com/alexeichhorn/YouTubeKit.git",
            revision: "7f75a2299dc329c0b7855afb25d47663a02855cb"
        )
    ],
    targets: [
        .target(name: "SlowroomCore", dependencies: ["YouTubeKit"]),
        .testTarget(name: "SlowroomCoreTests", dependencies: ["SlowroomCore"]),
        .executableTarget(name: "SourceProbe", dependencies: ["SlowroomCore"])
    ]
)
