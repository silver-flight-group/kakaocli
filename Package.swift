// swift-tools-version: 6.0

import Foundation
import PackageDescription

let sqlcipherPrefix = ProcessInfo.processInfo.environment["SQLCIPHER_PREFIX"]
    ?? ["/opt/homebrew/opt/sqlcipher", "/usr/local/opt/sqlcipher"]
        .first { FileManager.default.fileExists(atPath: "\($0)/include/sqlcipher/sqlite3.h") }
    ?? "/opt/homebrew/opt/sqlcipher"

let package = Package(
    name: "kakaocli",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kakaocli", targets: ["KakaoCLI"]),
        .library(name: "KakaoCore", targets: ["KakaoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "KakaoCLI",
            dependencies: [
                "KakaoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "KakaoCore",
            dependencies: ["CSQLCipher"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(sqlcipherPrefix)/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(sqlcipherPrefix)/lib",
                    "-lsqlcipher",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "\(sqlcipherPrefix)/lib",
                ]),
            ]
        ),
        .systemLibrary(
            name: "CSQLCipher",
            pkgConfig: "sqlcipher",
            providers: [.brew(["sqlcipher"])]
        ),
        .testTarget(
            name: "KakaoCoreTests",
            dependencies: ["KakaoCore"]
        ),
    ]
)
