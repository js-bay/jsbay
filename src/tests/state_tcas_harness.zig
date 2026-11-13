//! Aggregator for state_tcas harnesses (no ActiveEngine / JS vendors required).
//!
//! Includes real `js_event_loop.Scheduler` and `Driver` (+ Timer/Notifier) harnesses alongside toy ducks, plus L2 gap probes (`*_driver_gap.zig`).
//!
//! Explore files must stay free of L2 / `loop.dispatchEvents*` (see `build.zig` `check-state-tcas-explore-gates`).
//!
//! Run: `zig build test-state-tcas`
test {
    _ = @import("state_tcas_calendar_harness.zig");
    _ = @import("state_tcas_event_loop_harness.zig");
    _ = @import("state_tcas_js_event_loop_harness.zig");
    _ = @import("state_tcas_js_event_loop_driver_harness.zig");
    _ = @import("state_tcas_js_event_loop_driver_gap.zig");
    _ = @import("state_tcas_monitor_harness.zig");
    _ = @import("state_tcas_tla_harness.zig");
}
