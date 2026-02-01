const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;
const common = @import("common.zig");

/// Process management, such as waiting for process exit.
pub fn Process(comptime xev: type) type {
    if (xev.dynamic) return ProcessDynamic(xev);

    return switch (xev.backend) {
        // Supported, uses pidfd
        .io_uring,
        => ProcessPidFd(xev),

        .kqueue => ProcessKqueue(xev),
    };
}

/// Process implementation using pidfd (Linux).
fn ProcessPidFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.PollError || error{
            InvalidChild,
        };

        /// pidfd file descriptor
        fd: posix.fd_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: posix.pid_t) !Self {
            // Note: SOCK_NONBLOCK == PIDFD_NONBLOCK but we should PR that
            // over to Zig.
            const res = linux.pidfd_open(pid, posix.SOCK.NONBLOCK);
            const fd = switch (posix.errno(res)) {
                .SUCCESS => @as(posix.fd_t, @intCast(res)),
                .INVAL => return error.InvalidArgument,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NODEV => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            };

            return .{
                .fd = fd,
            };
        }

        /// Clean up the process watcher.
        pub fn deinit(self: *Self) void {
            std.posix.close(self.fd);
        }

        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            const events: u32 = posix.POLL.IN;

            c.* = .{
                .op = .{
                    .poll = .{
                        .fd = self.fd,
                        .events = events,
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        const arg: WaitError!u32 = arg: {
                            // If our poll failed, report that error.
                            _ = r.poll catch |err| break :arg err;

                            // We need to wait on the pidfd because it is noted as ready
                            const fd = c_inner.op.poll.fd;
                            var info: linux.siginfo_t = undefined;
                            const res = linux.waitid(.PIDFD, fd, &info, linux.W.EXITED);

                            break :arg switch (posix.errno(res)) {
                                .SUCCESS => @as(u32, @intCast(info.fields.common.second.sigchld.status)),
                                .CHILD => error.InvalidChild,

                                // The fd isn't ready to read, I guess?
                                .AGAIN => return .rearm,
                                else => |err| err: {
                                    std.log.warn("unexpected process wait errno={}", .{err});
                                    break :err error.Unexpected;
                                },
                            };
                        };

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            arg,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        test {
            _ = ProcessTests(
                xev,
                Self,
            );
        }
    };
}

fn ProcessKqueue(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.ProcError;

        /// The pid to watch.
        pid: posix.pid_t,

        /// Create a new process watcher for the given pid.
        pub fn init(pid: posix.pid_t) !Self {
            return .{
                .pid = pid,
            };
        }

        /// Does nothing for Kqueue.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Wait for the process to exit. This will automatically call
        /// `waitpid` or equivalent and report the exit status.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!u32,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .proc = .{
                        .pid = self.pid,
                        .flags = xev.Sys.NOTE_EXIT_FLAGS,
                    },
                },

                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        // Reap the process. We do this because our xev.Process
                        // docs note that this is the equivalent of calling
                        // `wait` on a process. The Linux side (pidfd) does this
                        // automatically since the `waitid` syscall is used.
                        if (r.proc) |_| {
                            _ = posix.waitpid(c_inner.op.proc.pid, 0);
                        } else |_| {}

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.proc) |v| v else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        test {
            _ = ProcessTests(
                xev,
                Self,
            );
        }
    };
}


fn ProcessDynamic(comptime dynamic: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = dynamic.Union(&.{"Process"});
        pub const WaitError = dynamic.ErrorSet(&.{ "Process", "WaitError" });

        pub fn init(fd: posix.pid_t) !Self {
            return .{ .backend = switch (dynamic.backend) {
                inline else => |tag| backend: {
                    const api = (comptime dynamic.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.Process.init(fd),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (dynamic.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        pub fn wait(
            self: Self,
            loop: *dynamic.Loop,
            c: *dynamic.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *dynamic.Loop,
                c: *dynamic.Completion,
                r: WaitError!u32,
            ) dynamic.CallbackAction,
        ) void {
            switch (dynamic.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime dynamic.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Process.WaitError!u32,
                        ) dynamic.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *dynamic.Loop.Union,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *dynamic.Completion.Union,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).wait(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = ProcessTests(
                dynamic,
                Self,
            );
        }
    };
}

fn ProcessTests(
    comptime xev: type,
    comptime Impl: type,
) type {
    return struct {
        const argv_0: []const []const u8 = &.{ "sh", "-c", "exit 0" };

        const argv_42: []const []const u8 = &.{ "sh", "-c", "exit 42" };

        test "process wait" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.process.Child.init(argv_0, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = .{};
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 0), code.?);
        }

        test "process wait with non-zero exit code" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.process.Child.init(argv_42, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = .{};
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 42), code.?);
        }

        test "process wait on a process that already exited" {
            const testing = std.testing;
            const alloc = testing.allocator;

            var child = std.process.Child.init(argv_0, alloc);
            try child.spawn();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var p = try Impl.init(child.id);
            defer p.deinit();

            _ = try child.wait();

            // Wait
            var code: ?u32 = null;
            var c_wait: xev.Completion = .{};
            p.wait(&loop, &c_wait, ?u32, &code, (struct {
                fn callback(
                    ud: ?*?u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!u32,
                ) xev.CallbackAction {
                    ud.?.* = r catch 0;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expectEqual(@as(u32, 0), code.?);
        }
    };
}
