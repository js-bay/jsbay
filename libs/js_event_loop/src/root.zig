//! JavaScript task-boundary coordination built on `zev` primitives.
//!
//! A `Driver` owns one `Scheduler` per JavaScript environment. It uses `SyncWait` while a native callback must return synchronously, and a `Task` around every queued unit that can execute JavaScript. After an outer task, it runs one non-reentrant microtask checkpoint.

pub const Scheduler = @import("scheduler.zig").Scheduler;
pub const Driver = @import("driver.zig").Driver;
pub const Timer = @import("driver.zig").Timer;
pub const Notifier = @import("driver.zig").Notifier;
pub const native_sync = @import("native_sync.zig");
pub const host_wake = @import("host_wake.zig");
