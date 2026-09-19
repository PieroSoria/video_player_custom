// swift-tools-version: 5.9

// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import PackageDescription

let package = Package(
  name: "video_player_custom",
  platforms: [
    .iOS("15.0"),
    .macOS("12.0"),
  ],
  products: [
    .library(name: "video-player-custom", targets: ["video_player_custom"])
  ],
  dependencies: [
    .package(name: "FlutterFramework", path: "../FlutterFramework")
  ],
  targets: [
    .target(
      name: "video_player_custom",
      dependencies: ["video_player_avfoundation", .product(name: "FlutterFramework", package: "FlutterFramework")],
      resources: [.process("PrivacyInfo.xcprivacy")]
    ),
    .target(
      name: "video_player_avfoundation",
      dependencies: [
        "video_player_avfoundation_objc",
        .product(name: "FlutterFramework", package: "FlutterFramework"),
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "video_player_avfoundation_objc",
      dependencies: [
        .product(name: "FlutterFramework", package: "FlutterFramework"),
        .target(name: "video_player_avfoundation_ios", condition: .when(platforms: [.iOS])),
        .target(name: "video_player_avfoundation_macos", condition: .when(platforms: [.macOS])),
      ],
      cSettings: [
        .headerSearchPath("include/video_player_avfoundation_objc")
      ]
    ),
    .target(
      name: "video_player_avfoundation_ios",
      dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],
      cSettings: [
        .headerSearchPath(
          "../video_player_avfoundation_objc/include/video_player_avfoundation_objc")
      ]
    ),
    .target(
      name: "video_player_avfoundation_macos",
      dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")],
      cSettings: [
        .headerSearchPath(
          "../video_player_avfoundation_objc/include/video_player_avfoundation_objc")
      ]
    ),
  ]
)
