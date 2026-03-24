// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropTest",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "drop_ffiFFI",
            path: "Sources/DropFFI"
        ),
        .executableTarget(
            name: "DropTest",
            dependencies: ["drop_ffiFFI"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L../../target/release",
                    "-L../../target/debug",
                    "-ldrop_ffi",
                ]),
            ]
        ),
    ]
)
