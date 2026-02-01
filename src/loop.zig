//! Common loop structures. The actual loop implementation is in backend-specific
//! files such as linux/io_uring.zig.

const std = @import("std");
const assert = std.debug.assert;
const xev = @import("main.zig");

/// Common options across backends. Not all options apply to all backends.
/// Read the doc comment for individual fields to learn what backends they
/// apply to.
pub const Options = struct {
    /// The number of queued completions that can be in flight before
    /// requiring interaction with the kernel.
    ///
    /// Backends: io_uring
    entries: u32 = 256,

    /// io_uring setup flags. These are passed directly to io_uring_setup().
    ///
    /// Backends: io_uring
    io_uring_flags: IoUringSetupFlags = .{},

    /// A thread pool to use for blocking operations. If the backend doesn't
    /// need to perform any blocking operations then no threads will ever
    /// be spawned. If the backend does need to perform blocking operations
    /// on a thread and no thread pool is provided, the operations will simply
    /// fail. Unless you're trying to really optimize for space, it is
    /// recommended you provide a thread pool.
    ///
    /// Backends: kqueue
    thread_pool: ?*xev.ThreadPool = null,
};

/// io_uring setup flags for configuring the ring behavior.
/// These correspond to IORING_SETUP_* flags passed to io_uring_setup().
pub const IoUringSetupFlags = packed struct(u32) {
    /// Perform busy-waiting for I/O completion instead of getting
    /// notifications via an async IRQ. Requires elevated privileges.
    iopoll: bool = false,

    /// Use a kernel thread to poll the submission queue. This enables
    /// truly async I/O by allowing submissions without system calls
    /// when the kernel thread is active.
    sqpoll: bool = false,

    /// Bind the kernel's poll thread to the CPU specified in sq_thread_cpu.
    /// Only valid when sqpoll is set.
    sq_aff: bool = false,

    /// Create the completion queue with the size specified in cq_entries.
    /// The value must be >= entries and may be rounded up to a power of two.
    cqsize: bool = false,

    /// Clamp entries and cq_entries to implementation-defined maximums
    /// instead of returning EINVAL.
    clamp: bool = false,

    /// Share the async backend of an existing ring. The fd of the
    /// existing ring is passed in wq_fd.
    attach_wq: bool = false,

    /// Start the ring in a disabled state. The ring must be enabled
    /// via io_uring_register() before submissions are allowed.
    r_disabled: bool = false,

    /// Continue submitting requests even if an error is encountered
    /// during submission. Without this, submission stops at the first error.
    submit_all: bool = false,

    /// Cooperative task running. When set, io_uring will not interrupt
    /// a task when async completions are ready; the task must explicitly
    /// check for completions. Can reduce context switches.
    coop_taskrun: bool = false,

    /// Used with coop_taskrun - always set the task running flag when
    /// completions are ready, even if they can be processed inline.
    taskrun_flag: bool = false,

    /// Use 128-byte SQEs instead of the default 64-byte SQEs. Allows
    /// larger inline data for certain operations.
    sqe128: bool = false,

    /// Use 32-byte CQEs instead of the default 16-byte CQEs. Provides
    /// more space for completion data.
    cqe32: bool = false,

    /// Hint that only a single task will submit requests. Enables
    /// internal optimizations.
    single_issuer: bool = false,

    /// Defer running task work to when the task transitions to userspace.
    /// Must be used with single_issuer. Reduces kernel overhead for
    /// batched submissions.
    defer_taskrun: bool = false,

    /// Don't mmap the rings into userspace. The application must use
    /// registered ring fds. For advanced use cases.
    no_mmap: bool = false,

    /// Only allow registered file descriptors. All file descriptors
    /// must be registered before use.
    registered_fd_only: bool = false,

    /// Don't allocate an SQ array. The application indexes directly
    /// into the SQE array.
    no_sqarray: bool = false,

    _padding: u15 = 0,

    /// Convert to the raw u32 flags value for passing to the kernel.
    pub fn toInt(self: IoUringSetupFlags) u32 {
        return @bitCast(self);
    }

    /// Create from a raw u32 flags value.
    pub fn fromInt(value: u32) IoUringSetupFlags {
        return @bitCast(value);
    }
};

/// The loop run mode -- all backends are required to support this in some way.
/// Backends may provide backend-specific APIs that behave slightly differently
/// or in a more configurable way.
pub const RunMode = enum(c_int) {
    /// Run the event loop once. If there are no blocking operations ready,
    /// return immediately.
    no_wait = 0,

    /// Run the event loop once, waiting for at least one blocking operation
    /// to complete.
    once = 1,

    /// Run the event loop until it is "done". "Doneness" is defined as
    /// there being no more completions that are active.
    until_done = 2,
};

/// The callback of the main Loop operations. Higher level interfaces may
/// use a different callback mechanism.
pub fn Callback(comptime T: type) type {
    return *const fn (
        userdata: ?*anyopaque,
        loop: *T.Loop,
        completion: *T.Completion,
        result: T.Result,
    ) CallbackAction;
}

/// A callback that does nothing and immediately disarms. This
/// implements xev.Callback and is the default value for completions.
pub fn NoopCallback(comptime T: type) Callback(T) {
    return (struct {
        pub fn noopCallback(
            _: ?*anyopaque,
            _: *T.Loop,
            _: *T.Completion,
            _: T.Result,
        ) CallbackAction {
            return .disarm;
        }
    }).noopCallback;
}

/// The result type for callbacks. This should be used by all loop
/// implementations and higher level abstractions in order to control
/// what to do after the loop completes.
pub const CallbackAction = enum(c_int) {
    /// The request is complete and is not repeated. For example, a read
    /// callback only fires once and is no longer watched for reads. You
    /// can always free memory associated with the completion prior to
    /// returning this.
    disarm = 0,

    /// Requeue the same operation request with the same parameters
    /// with the event loop. This makes it easy to repeat a read, timer,
    /// etc. This rearms the request EXACTLY as-is. For example, the
    /// low-level timer interface for io_uring uses an absolute timeout.
    /// If you rearm the timer, it will fire immediately because the absolute
    /// timeout will be in the past.
    ///
    /// The completion is reused so it is not safe to use the same completion
    /// for anything else.
    rearm = 1,
};

/// The state that a completion can be in.
pub const CompletionState = enum(c_int) {
    /// The completion is not being used and is ready to be configured
    /// for new work.
    dead = 0,

    /// The completion is part of an event loop. This may be already waited
    /// on or in the process of being registered.
    active = 1,
};

const testing = @import("std").testing;
const linux = @import("std").os.linux;

test "IoUringSetupFlags bit layout" {
    // Verify the flags match the kernel constants
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_IOPOLL), (IoUringSetupFlags{ .iopoll = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_SQPOLL), (IoUringSetupFlags{ .sqpoll = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_SQ_AFF), (IoUringSetupFlags{ .sq_aff = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_CQSIZE), (IoUringSetupFlags{ .cqsize = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_CLAMP), (IoUringSetupFlags{ .clamp = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_ATTACH_WQ), (IoUringSetupFlags{ .attach_wq = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_R_DISABLED), (IoUringSetupFlags{ .r_disabled = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_SUBMIT_ALL), (IoUringSetupFlags{ .submit_all = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_COOP_TASKRUN), (IoUringSetupFlags{ .coop_taskrun = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_TASKRUN_FLAG), (IoUringSetupFlags{ .taskrun_flag = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_SQE128), (IoUringSetupFlags{ .sqe128 = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_CQE32), (IoUringSetupFlags{ .cqe32 = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_SINGLE_ISSUER), (IoUringSetupFlags{ .single_issuer = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_DEFER_TASKRUN), (IoUringSetupFlags{ .defer_taskrun = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_NO_MMAP), (IoUringSetupFlags{ .no_mmap = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_REGISTERED_FD_ONLY), (IoUringSetupFlags{ .registered_fd_only = true }).toInt());
    try testing.expectEqual(@as(u32, linux.IORING_SETUP_NO_SQARRAY), (IoUringSetupFlags{ .no_sqarray = true }).toInt());

    // Test combining multiple flags
    const combined = IoUringSetupFlags{
        .single_issuer = true,
        .coop_taskrun = true,
    };
    try testing.expectEqual(
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_COOP_TASKRUN,
        combined.toInt(),
    );
}
