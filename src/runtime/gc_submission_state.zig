pub const GcSubmissionState = enum(u8) {
    idle = 0,
    submitting = 1,
    queued = 2,
};
