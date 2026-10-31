// swift-tools-version: 6.0
// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "LowlightAudio",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LowlightAudio", targets: ["LowlightAudio"])],
    targets: [
        .target(name: "LowlightAudio"),
        .testTarget(name: "LowlightAudioTests", dependencies: ["LowlightAudio"]),
    ]
)
