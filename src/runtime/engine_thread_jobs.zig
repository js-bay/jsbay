pub fn cancelAll(state: anytype, destroyed_status: c_int, free_job: anytype, notify_locked: anytype) void {
    state.queue_mu.lock();
    var reap: @TypeOf(state.head) = null;
    var it = state.jobs.iterator();
    while (it.next()) |entry| {
        const job = entry.value_ptr.*;
        if (job.settled) continue;
        job.settled = true;
        job.status = destroyed_status;
        if (job.auto_release and job.waiters == 0 and !job.on_stack) {
            job.next = reap;
            reap = job;
        }
    }
    state.head = null;
    state.tail = null;
    // A queued native task belongs to the current thread run. Stop cancels it before restart can accidentally execute its borrowed data pointer.
    state.native_task = null;
    state.has_native.store(false, .seq_cst);
    var current = reap;
    while (current) |job| : (current = job.next) {
        _ = state.jobs.remove(job.id);
    }
    notify_locked(state);
    state.queue_mu.unlock();

    current = reap;
    while (current) |job| {
        const next = job.next;
        free_job(job);
        current = next;
    }
}

pub fn freeJobs(state: anytype, free_job: anytype) void {
    var it = state.jobs.iterator();
    while (it.next()) |entry| free_job(entry.value_ptr.*);
    state.jobs.clearRetainingCapacity();
}
