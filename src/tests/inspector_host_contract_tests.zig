//! Runs inspector module contracts that require the engine's actual Host.
//!
//! These module tests are authored beside their implementation in `libs/inspector`. They require the engine-facing Host, so the root test suite explicitly invokes them here.

const inspector = @import("../inspector/root.zig");

test "inspector state shutdown waits for an in-flight callback lease" {
    try inspector.state.TestCases.stateShutdownWaitsForInFlightCallbackLease();
}

test "inspector state shutdown waits for a task already removed from its queue" {
    try inspector.state.TestCases.stateShutdownWaitsForTaskAlreadyRemovedFromQueue();
}

test "inspector task count rolls back failed posts and canceled tasks" {
    try inspector.state.TestCases.taskCountRollsBackFailedPostsAndCanceledTasks();
}

test "public and console groups with the same name release independently" {
    try inspector.object_table.TestCases.publicAndConsoleGroupsWithSameNameReleaseIndependently();
}

test "Debugger.enable cannot reopen the gate after Inspector closing begins" {
    try inspector.debugger_cdp.TestCases.debuggerEnableCannotReopenGateAfterClosingBegins();
}
