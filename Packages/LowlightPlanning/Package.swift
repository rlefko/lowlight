// swift-tools-version: 6.0
// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import PackageDescription

let package = Package(
    name: "LowlightPlanning",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "LowlightPlanning", targets: ["LowlightPlanning"])],
    targets: [
        .target(name: "LowlightPlanning", resources: [.process("Resources")]),
        .testTarget(name: "LowlightPlanningTests", dependencies: ["LowlightPlanning"]),
    ]
)
