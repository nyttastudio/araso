// swift-tools-version:6.2
import PackageDescription

var products: [Product] = [
    .library(name: "ArasoCore", targets: ["ArasoCore"]),
    .executable(name: "araso-cli", targets: ["araso-cli"]),
    // Windows: the host process loads it (windows/host); see docs/windows-port.md.
    .library(name: "ArasoBridge", type: .dynamic, targets: ["ArasoBridge"]),
]

var targets: [Target] = [
    .target(name: "ArasoCore", dependencies: [
        // The dictionary is shipped in Araso.app/Contents/Resources and passed by path
        // (see JapaneseConverter), not through an SPM resource bundle.
        .product(name: "KanaKanjiConverterModule", package: "AzooKeyKanaKanjiConverter"),
    ]),
    // What InputMethodKit and the Araso app give on macOS, for the Windows input method: sessions per
    // text field over a snapshot of it, keys, the menu, settings. Portable, so it is tested on macOS too.
    .target(name: "ArasoService", dependencies: ["ArasoCore"]),
    .target(name: "ArasoBridge", dependencies: ["ArasoService"]),
    .executableTarget(name: "araso-cli", dependencies: ["ArasoCore"]),
    .testTarget(name: "ArasoCoreTests", dependencies: ["ArasoCore"]),
    .testTarget(name: "ArasoServiceTests", dependencies: ["ArasoService", "ArasoBridge"]),
]

// The macOS input method (InputMethodKit, AppKit) builds only there.
#if os(macOS)
products.append(.executable(name: "Araso", targets: ["Araso"]))
targets.append(.executableTarget(name: "Araso", dependencies: ["ArasoCore"]))
#endif

let package = Package(
    name: "Araso",
    platforms: [.macOS(.v13)],
    products: products,
    dependencies: [
        // Kana-kanji conversion. Code MIT, dictionary Apache-2.0. No Zenzai (neural) trait.
        .package(url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter", .upToNextMinor(from: "0.8.0")),
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
