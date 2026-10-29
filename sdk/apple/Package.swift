// swift-tools-version: 5.9
import PackageDescription

// The release packager keeps this manifest next to Sources and Frameworks.
let package = Package(
  name: "JsBay",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [
    .library(name: "JsBaySDK", targets: ["JsBaySDK"]),
    .library(name: "JsBayObjC", targets: ["JsBayObjC"]),
  ],
  targets: [
    .binaryTarget(name: "JsBay", path: "Frameworks/JsBay.xcframework"),
    .target(
      name: "JsBaySDK",
      dependencies: ["JsBay"],
      linkerSettings: [.linkedFramework("JavaScriptCore")]
    ),
    .target(
      name: "JsBayObjC",
      dependencies: ["JsBay"],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore")]
    ),
  ]
)
