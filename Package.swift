// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermesBackup",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HermesBackup", path: "Sources/HermesBackup"),
        .testTarget(name: "HermesBackupTests", dependencies: ["HermesBackup"], path: "Tests/HermesBackupTests"),
    ]
)
