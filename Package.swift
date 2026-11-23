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
    .binaryTarget(name: "JsBayQuickJS", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.2/jsbay-0.1.2-apple-quickjs-JsBayQuickJS.xcframework.zip", checksum: "ce900bf2c485aa500d0c46984dd3c600a4dde2464407b2d6d001dfe4b5377de9"),
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
    .binaryTarget(name: "JsBayQuickJSNG", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.2/jsbay-0.1.2-apple-quickjs_ng-JsBayQuickJSNG.xcframework.zip", checksum: "f047eee232dfe52505d8fcdbccd258bdc2ae86c60ff1da54bda4194b61f664f1"),
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
    .binaryTarget(name: "JsBayJavaScriptCore", url: "https://github.com/js-bay/jsbay/releases/download/v0.1.2/jsbay-0.1.2-apple-jsc-JsBayJavaScriptCore.xcframework.zip", checksum: "463b16dece7fdfbc0cde7a8be9d76ce224a60c89f1c0bde85b71dce413fb577b"),
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
