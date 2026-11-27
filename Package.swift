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
    .binaryTarget(name: "JsBayQuickJS", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.3/jsbay-0.1.3-apple-quickjs-JsBayQuickJS.xcframework.zip", checksum: "bc34b1d98fd011b443b497bf726cae9b784f91a6d1ad7074e415b58a47b9b4de"),
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
    .binaryTarget(name: "JsBayQuickJSNG", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.3/jsbay-0.1.3-apple-quickjs_ng-JsBayQuickJSNG.xcframework.zip", checksum: "0c7d97d3fcd9282f585781cb0246003c6e30083d0bb650428a14bf82d85f1d76"),
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
    .binaryTarget(name: "JsBayJavaScriptCore", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.3/jsbay-0.1.3-apple-jsc-JsBayJavaScriptCore.xcframework.zip", checksum: "e106815d9b39f211ec4c049e11379cc67243c217308cefb6d31bcd759a8cfe35"),
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
