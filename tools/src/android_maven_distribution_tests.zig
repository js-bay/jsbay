const std = @import("std");

fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "Android release publishes Maven metadata and supports both coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const release = try read(allocator, io, ".github/workflows/release.yml");
    const gradle = try read(allocator, io, "sdk/android/jsbay/build.gradle.kts");
    for ([_][]const u8{ "maven-publish", "implementation(\"org.jetbrains.kotlin:kotlin-stdlib", "\"quickjs\" -> \"jsbay-quickjs\"", "\"quickjs_ng\" -> \"jsbay-quickjs-ng\"", "\"quickjs\" -> \"jsbayquickjs\"", "\"quickjs_ng\" -> \"jsbayquickjsng\"", "if (name == \"releaseVariantReleaseApiPublication\" || name == \"releaseVariantReleaseRuntimePublication\")", "outgoing.capability(\"io.jsbay:$jsbayArtifactId:$version\")", "outgoing.capability(\"io.jsbay:$jsbayLegacyArtifactId:$version\")", "assets/jsbay-backend.txt", "artifactId = jsbayArtifactId", "name = \"GitHubPackages\"", "https://maven.pkg.github.com/${githubRepository.lowercase()}", "GITHUB_ACTOR", "GITHUB_TOKEN" }) |needle| try contains(gradle, needle);
    const publisher = try read(allocator, io, "scripts/publish-android-maven.sh");
    const consumer = try read(allocator, io, "tests/android-sdk/maven-consumer.sh");
    for ([_][]const u8{ "jsbayquickjs", "jsbayquickjsng", "check-maven \"$module_dir\" \"$version\" \"$backend\" \"$artifact\"" }) |needle| try contains(publisher, needle);
    for ([_][]const u8{ "jsbayquickjs", "jsbayquickjsng", "No published Maven artifact found" }) |needle| try contains(consumer, needle);
    for ([_][]const u8{ ":jsbay:publishReleasePublicationToStagingRepository", "-PjsbayVersion=", "-PjsbayBackend=\"$backend\"", "-PjsbayMavenRepo=", "archive=\"jsbay-${ver}-android-${backend}-maven.zip\"", "tests/android-sdk/maven-consumer.sh", "env -u ANDROID_HOME ANDROID_SDK_ROOT=\"$ANDROID_SDK_ROOT\"", "-PjsbayVersion=\"${{ steps.ver.outputs.label }}\"", "tool -- check-maven \"$module\" \"$ver\" \"$backend\"" }) |needle| try contains(release, needle);
}
