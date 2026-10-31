// swift-tools-version: 6.0
// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "LowlightAudio",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LowlightAudio", targets: ["LowlightAudio"])],
    dependencies: [.package(path: "../LowlightPlanning")],
    targets: [
        .target(
            name: "CLowlightDSP",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-ffp-contract=off"])]
        ),
        .target(name: "LowlightAudio", dependencies: ["CLowlightDSP", "LowlightPlanning"]),
        .testTarget(name: "LowlightAudioTests", dependencies: ["LowlightAudio"]),
    ],
    cxxLanguageStandard: .cxx17
)
