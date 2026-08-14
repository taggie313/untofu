// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "fontfetch",
    platforms: [.macOS(.v12)],
    targets: [
        // Thin C shim that owns the CoreText font-request hook. Kept deliberately
        // small: it is the only place where CoreFoundation ownership rules and the
        // undocumented return contract of the hook matter.
        .target(
            name: "CFontProvider",
            cSettings: [.unsafeFlags(["-fblocks", "-Wno-deprecated-declarations"])],
            linkerSettings: [
                .linkedFramework("CoreText"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "fontfetch",
            dependencies: ["CFontProvider"]
        ),
    ]
)
