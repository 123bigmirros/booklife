// swift-tools-version: 5.9
import PackageDescription
import Foundation

let package = Package(
    name: "booklife",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "booklifeMac", targets: ["BookSlideMac"]), .executable(name: "booklife", targets: ["BookSlideCLI"]), .executable(name: "bookslide", targets: ["BookSlideCLI"])],
    targets: [
        .target(name: "BookSlideCore"),
        .target(name: "BookSlideTransport", dependencies: ["BookSlideCore"]),
        .target(name: "BookSlideTerminal", dependencies: ["BookSlideCore"]),
        .executableTarget(name: "BookSlideCLI", dependencies: ["BookSlideTerminal", "BookSlideCore", "BookSlideTransport"]),
        .testTarget(name: "BookSlideTerminalTests", dependencies: ["BookSlideTerminal"]),
        .executableTarget(name: "BookSlideMac", dependencies: ["BookSlideCore", "BookSlideTransport", "BookSlideTerminal"], resources: [.copy("Resources/Reader")]),
        .testTarget(name: "BookSlideCoreTests", dependencies: ["BookSlideCore"]),
        .testTarget(name: "BookSlideMacTests", dependencies: ["BookSlideMac", "BookSlideCore"]),
        .testTarget(name: "BookSlideTransportTests", dependencies: ["BookSlideTransport", "BookSlideCore"])
    ]
)

// Ignore conflict copies recreated by cloud sync; local history lives in build/.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
for target in package.targets {
    let folder = target.type == .test ? "Tests" : "Sources"
    let directory = packageRoot.appendingPathComponent("\(folder)/\(target.name)")
    if let files = FileManager.default.enumerator(atPath: directory.path) {
        target.exclude += files.compactMap { item -> String? in
            guard let path = item as? String else { return nil }
            if URL(fileURLWithPath: path).lastPathComponent.contains(".sync-conflict-") {
                files.skipDescendants()
                return path
            }
            return nil
        }
    }
}
