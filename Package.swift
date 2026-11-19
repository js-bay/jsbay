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
    .binaryTarget(name: "JsBayQuickJS", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.1-rc.2/jsbay-0.1.1-rc.2-apple-quickjs-JsBayQuickJS.xcframework.zip", checksum: "f40127b3c8d2fb41df3f0ffcdc5a33ca6a5bc73d338db12df710f211282ce574"),
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
    .binaryTarget(name: "JsBayQuickJSNG", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.1-rc.2/jsbay-0.1.1-rc.2-apple-quickjs_ng-JsBayQuickJSNG.xcframework.zip", checksum: "95059ea4a131c9bc51d72429343234bda309bd9e53f8b5327cd8deed40b92e85"),
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
    .binaryTarget(name: "JsBayJavaScriptCore", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.1-rc.2/jsbay-0.1.1-rc.2-apple-jsc-JsBayJavaScriptCore.xcframework.zip", checksum: "24e6668a3930c614291bca3bc99042444453274cf9f46d4b7bdc20ea8ee026a1"),
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
