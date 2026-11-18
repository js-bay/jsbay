// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "JsBay",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [
    .library(name: "JsBayQuickJSSDK", targets: ["JsBayQuickJSSDK"]),
    .library(name: "JsBayQuickJSObjC", targets: ["JsBayQuickJSObjC"]),
    .library(name: "JsBayQuickJSNGSDK", targets: ["JsBayQuickJSNGSDK"]),
    .library(name: "JsBayQuickJSNGObjC", targets: ["JsBayQuickJSNGObjC"]),
    .library(name: "JsBayJavaScriptCoreSDK", targets: ["JsBayJavaScriptCoreSDK"]),
    .library(name: "JsBayJavaScriptCoreObjC", targets: ["JsBayJavaScriptCoreObjC"]),
  ],
  targets: [
    .binaryTarget(name: "JsBayQuickJS", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.1-rc.1/jsbay-0.1.1-rc.1-apple-quickjs-JsBayQuickJS.xcframework.zip", checksum: "3f72c5acf32b2a8cc441ba07a1d03fd11b98bc208c4c885d01df41deda859380"),
    .target(
      name: "JsBayQuickJSSDK",
      dependencies: [.target(name: "JsBayQuickJS")],
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .target(
      name: "JsBayQuickJSObjC",
      dependencies: [.target(name: "JsBayQuickJS")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .binaryTarget(name: "JsBayQuickJSNG", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.1-rc.1/jsbay-0.1.1-rc.1-apple-quickjs_ng-JsBayQuickJSNG.xcframework.zip", checksum: "5632f146ff90021e14b5903679cd20e78a94ccd79d1953df00f1db386fcd696e"),
    .target(
      name: "JsBayQuickJSNGSDK",
      dependencies: [.target(name: "JsBayQuickJSNG")],
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .target(
      name: "JsBayQuickJSNGObjC",
      dependencies: [.target(name: "JsBayQuickJSNG")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .binaryTarget(name: "JsBayJavaScriptCore", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.1-rc.1/jsbay-0.1.1-rc.1-apple-jsc-JsBayJavaScriptCore.xcframework.zip", checksum: "e512026a3a688779447e7821057599e5937bab92ce2db54b2e6aec6480ccdadb"),
    .target(
      name: "JsBayJavaScriptCoreSDK",
      dependencies: [.target(name: "JsBayJavaScriptCore")],
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
    .target(
      name: "JsBayJavaScriptCoreObjC",
      dependencies: [.target(name: "JsBayJavaScriptCore")],
      publicHeadersPath: "include",
      linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Foundation"), .linkedLibrary("m")]
    ),
  ]
)
