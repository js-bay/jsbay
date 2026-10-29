//! Lifecycle contract for the reflection helpers used by Runtime.getProperties.
//!
//! Keeping these JS values alive only makes sense while an Inspector session needs them. Ordinary engine creation and evaluation must not retain them merely because the binary was built with Inspector support.

const std = @import("std");
const testing = std.testing;

const engine = @import("../engine.zig");
const inspector_state = @import("../inspector/root.zig").state;
const helpers = @import("test_helpers.zig");

test "inspector cost: an engine without Inspector retains no Runtime reflection snapshot" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const evaluated = engine.evalScript(id, "globalThis.applicationDidRun = true;", "ordinary-no-inspector.js");
    defer helpers.freeEvalResult(evaluated);
    try testing.expect(evaluated.err == null);

    // Retaining Object/Reflect functions from an ordinary runtime keeps JS values alive for a debugger the application never started. This is a per-instance resource assertion, so unrelated Inspector sessions do not affect the result.
    try testing.expect(!inspector_state.hasPristineRuntimeIntrinsicsForTesting(id));
}
