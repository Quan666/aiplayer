// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "sqlite3_flutter_libs",
    platforms: [.iOS("12.0"), .macOS("10.14")],
    products: [
        .library(name: "sqlite3-flutter-libs", type: .static, targets: ["sqlite3_flutter_libs"])
    ],
    // Consume a dynamic product, as the original remote CSQLite package did.
    // A same-package target dependency can otherwise be linked statically and
    // omit the standalone framework expected by package:sqlite3's loader.
    dependencies: [.package(path: "Sources/CSQLite")],
    targets: [
        .target(name: "sqlite3_flutter_libs", dependencies: [
            .product(name: "CSQLite", package: "CSQLite")
        ])
    ]
)
