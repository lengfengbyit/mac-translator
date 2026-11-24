// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacTranslator",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacTranslator", targets: ["MacTranslator"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacTranslator",
            path: "Sources/MacTranslator",
            exclude: [
                "Resources/Info.plist",
                "Resources/MacTranslator.entitlements"
            ],
            resources: [
                .copy("Resources/Assets.xcassets"),
                .copy("Resources/Model.xcdatamodeld")
            ]
        ),
        .testTarget(
            name: "MacTranslatorTests",
            dependencies: ["MacTranslator"],
            path: "Tests/MacTranslatorTests"
        )
    ]
)
