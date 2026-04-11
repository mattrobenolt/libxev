const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;

const ThreadPool = @import("../ThreadPool.zig");
const common = @import("common.zig");
const stream = @import("stream.zig");

/// TCP client and server.
///
/// This is a "higher-level abstraction" in libxev. The goal of higher-level
/// abstractions in libxev are to make it easier to use specific functionality
/// with the event loop, but does not promise perfect flexibility or optimal
/// performance. In almost all cases, the abstraction is good enough. But,
/// if you have specific needs or want to push for the most optimal performance,
/// use the platform-specific Loop directly.
pub fn TCP(comptime xev: type) type {
    return TCPStream(xev);
}

fn TCPStream(comptime xev: type) type {
    return struct {
        const Self = @This();
        const FdType = posix.socket_t;

        fd: FdType,

        const S = stream.Stream(xev, Self, .{
            .close = true,
            .poll = true,
            .read = .recv,
            .write = .send,
        });
        pub const close = S.close;
        pub const poll = S.poll;
        pub const read = S.read;
        pub const write = S.write;
        pub const writeInit = S.writeInit;
        pub const queueWrite = S.queueWrite;

        /// Initialize a new TCP with the family from the given address. Only
        /// the family is used, the actual address has no impact on the created
        /// resource.
        pub fn init(addr: std.net.Address) !Self {
            const fd = fd: {
                // On io_uring we don't use non-blocking sockets because we may
                // just get EAGAIN over and over from completions.
                const flags = flags: {
                    var flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
                    if (xev.backend != .io_uring) flags |= posix.SOCK.NONBLOCK;
                    break :flags flags;
                };
                break :fd try posix.socket(addr.any.family, flags, 0);
            };

            return .{
                .fd = fd,
            };
        }

        /// Initialize a TCP socket from a file descriptor.
        pub fn initFd(fd: FdType) Self {
            return .{
                .fd = fd,
            };
        }

        /// Bind the address to the socket.
        pub fn bind(self: Self, addr: std.net.Address) !void {
            try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            try posix.bind(self.fd, &addr.any, addr.getOsSockLen());
        }

        /// Listen for connections on the socket. This puts the socket into passive
        /// listening mode. Connections must still be accepted one at a time.
        pub fn listen(self: Self, backlog: u31) !void {
            try posix.listen(self.fd, backlog);
        }

        /// Accept a single connection.
        pub fn accept(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.AcceptError!Self,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .accept = .{
                        .socket = self.fd,
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
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.accept) |fd| initFd(fd) else |err| err,
                        });
                    }
                }).callback,
            };

            // If we're dup-ing, then we ask the backend to manage the fd.
            switch (xev.backend) {
                .io_uring, .kqueue => {},
            }

            loop.add(c);
        }

        /// Accept connections in multishot mode.
        ///
        /// In multishot mode, the callback is invoked for each incoming connection
        /// without needing to rearm the operation. Return `.disarm` from the callback
        /// to stop accepting connections, or `.rearm` to continue (though on io_uring
        /// with multishot, rearm is automatic and returning `.rearm` is a no-op).
        ///
        /// On io_uring (kernel 5.19+), this uses true multishot accept where a single
        /// submission can accept multiple connections.
        ///
        /// On kqueue, the multishot flag is ignored and you must return `.rearm` from
        /// the callback to accept additional connections (same behavior as regular
        /// accept with manual rearming).
        pub fn acceptMultishot(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: xev.AcceptError!Self,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .accept = .{
                        .socket = self.fd,
                        .multishot = true,
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
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.accept) |fd| initFd(fd) else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Establish a connection as a client.
        pub fn connect(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            addr: std.net.Ip4Address,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: xev.ConnectError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .connect = .{
                        .socket = self.fd,
                        .addr = addr.sa,
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
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            initFd(c_inner.op.connect.socket),
                            if (r.connect) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Shutdown the socket. This always only shuts down the writer side. You
        /// can use the lower level interface directly to control this if the
        /// platform supports it.
        pub fn shutdown(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: xev.ShutdownError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .shutdown = .{
                        .socket = self.fd,
                        .how = .send,
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
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            initFd(c_inner.op.shutdown.socket),
                            if (r.shutdown) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Receive data in multishot mode using a buffer from the provided BufferPool.
        ///
        /// In multishot mode, the callback is invoked for each incoming chunk of data
        /// without needing to rearm the operation. Return `.disarm` from the callback
        /// to stop receiving, or `.rearm` to continue (on io_uring with multishot,
        /// rearm is automatic while `IORING_CQE_F_MORE` is set; `.rearm` resubmits
        /// when the multishot terminates, e.g. on buffer exhaustion).
        ///
        /// On io_uring (kernel 6.0+), this uses true multishot recv where a single
        /// submission generates multiple completions as data arrives.
        ///
        /// On kqueue, multishot is not supported and this falls back to regular
        /// single-shot recvWithPool. Return `.rearm` from the callback to receive
        /// additional data.
        pub fn recvWithPoolMultishot(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            pool: *xev.BufferPool,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: xev.RecvPoolError!xev.BufferPool.Recv,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                .io_uring => {
                    c.* = .{
                        .op = .{
                            .recv_pool = .{
                                .fd = self.fd,
                                .buffer_group_id = pool.config.group_id,
                                .pool = pool,
                                .multishot = true,
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
                                const op = &c_inner.op.recv_pool;
                                const pool_ptr: *xev.BufferPool = @ptrCast(@alignCast(op.pool));
                                const res = r.recv_pool;

                                const user_result: xev.RecvPoolError!xev.BufferPool.Recv = blk: {
                                    const bytes_read = res.result catch |err| break :blk err;
                                    const buffer_id = res.cqe.buffer_id() catch break :blk error.NoBuffersAvailable;
                                    break :blk pool_ptr.getRecvFromResult(buffer_id, bytes_read, res.cqe);
                                };

                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, ud),
                                    l_inner,
                                    c_inner,
                                    initFd(op.fd),
                                    user_result,
                                });
                            }
                        }).callback,
                    };
                },
                .kqueue => {
                    // kqueue doesn't support multishot recv; fall back to single-shot.
                    return self.recvWithPool(loop, c, pool, Userdata, userdata, cb);
                },
            }
            loop.add(c);
        }

        /// Receive data using a buffer from the provided BufferPool.
        /// On io_uring (kernel 6.0+), the kernel selects the buffer from the
        /// registered buffer ring. On kqueue, a buffer is acquired from the
        /// user-space pool before the operation.
        pub fn recvWithPool(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            pool: *xev.BufferPool,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: xev.RecvPoolError!xev.BufferPool.Recv,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                .io_uring => {
                    c.* = .{
                        .op = .{
                            .recv_pool = .{
                                .fd = self.fd,
                                .buffer_group_id = pool.config.group_id,
                                .pool = pool,
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
                                const op = &c_inner.op.recv_pool;
                                const pool_ptr: *xev.BufferPool = @ptrCast(@alignCast(op.pool));
                                const res = r.recv_pool;

                                const user_result: xev.RecvPoolError!xev.BufferPool.Recv = blk: {
                                    const bytes_read = res.result catch |err| break :blk err;
                                    const buffer_id = res.cqe.buffer_id() catch break :blk error.NoBuffersAvailable;
                                    // Don't return buffer to kernel here - user will call release() when done
                                    break :blk pool_ptr.getRecvFromResult(buffer_id, bytes_read, res.cqe);
                                };

                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, ud),
                                    l_inner,
                                    c_inner,
                                    initFd(op.fd),
                                    user_result,
                                });
                            }
                        }).callback,
                    };
                },
                .kqueue => {
                    // For kqueue, acquire buffer upfront
                    const buffer = pool.acquire() orelse {
                        // No buffers available - we need to handle this case
                        c.* = .{
                            .op = .{
                                .recv_pool = .{
                                    .fd = self.fd,
                                    .pool = pool,
                                    .buffer_id = 0,
                                    .buffer = &.{},
                                },
                            },
                            .userdata = userdata,
                            .callback = (struct {
                                fn callback(
                                    ud: ?*anyopaque,
                                    l_inner: *xev.Loop,
                                    c_inner: *xev.Completion,
                                    _: xev.Result,
                                ) xev.CallbackAction {
                                    return @call(.always_inline, cb, .{
                                        common.userdataValue(Userdata, ud),
                                        l_inner,
                                        c_inner,
                                        initFd(c_inner.op.recv_pool.fd),
                                        @as(xev.RecvPoolError!xev.BufferPool.Recv, error.NoBuffersAvailable),
                                    });
                                }
                            }).callback,
                        };
                        loop.add(c);
                        return;
                    };

                    c.* = .{
                        .op = .{
                            .recv_pool = .{
                                .fd = self.fd,
                                .pool = pool,
                                .buffer_id = buffer.buffer_id,
                                .buffer = buffer.data,
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
                                const op = &c_inner.op.recv_pool;
                                const pool_ptr: *xev.BufferPool = @ptrCast(@alignCast(op.pool));
                                const res = r.recv_pool;

                                const user_result: xev.RecvPoolError!xev.BufferPool.Recv = blk: {
                                    const bytes_read = res.result catch |err| {
                                        // Release the buffer on error
                                        pool_ptr.releaseBuffer(res.buffer_id, {});
                                        break :blk err;
                                    };
                                    break :blk pool_ptr.getRecvFromResult(res.buffer_id, bytes_read, {});
                                };

                                const action = @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, ud),
                                    l_inner,
                                    c_inner,
                                    initFd(op.fd),
                                    user_result,
                                });

                                // Auto-release buffer on disarm (unless user already released)
                                if (action == .disarm) {
                                    if (res.result) |_| {
                                        // User is responsible for releasing when successful
                                    } else |_| {
                                        // Already released on error above
                                    }
                                }

                                return action;
                            }
                        }).callback,
                    };
                },
            }
            loop.add(c);
        }

        /// Receive data using recvmsg with a buffer from the provided BufferPool.
        /// The msghdr is caller-owned and must remain valid until the callback fires.
        /// The msghdr's iov[0] will be overwritten by the pool buffer on completion.
        /// The msghdr's control/controllen fields are passed through to the kernel,
        /// allowing the caller to receive ancillary data (e.g. kTLS record type via cmsg).
        ///
        /// Linux/io_uring only. The kernel selects the payload buffer from the
        /// registered buffer ring (IOSQE_BUFFER_SELECT); the control buffer is caller-owned.
        pub fn recvmsgWithPool(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            pool: *xev.BufferPool,
            msghdr: *posix.msghdr,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                s: Self,
                r: xev.RecvPoolError!xev.BufferPool.Recv,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                .io_uring => {
                    c.* = .{
                        .op = .{
                            .recvmsg = .{
                                .fd = self.fd,
                                .msghdr = msghdr,
                                .buffer_group_id = pool.config.group_id,
                                .pool = pool,
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
                                const op = &c_inner.op.recvmsg;
                                const pool_ptr: *xev.BufferPool = @ptrCast(@alignCast(op.pool.?));
                                const res = r.recvmsg;

                                const user_result: xev.RecvPoolError!xev.BufferPool.Recv = blk: {
                                    const bytes_read = res.result catch |err| break :blk err;
                                    const buffer_id = res.cqe.buffer_id() catch break :blk error.NoBuffersAvailable;
                                    break :blk pool_ptr.getRecvFromResult(buffer_id, bytes_read, res.cqe);
                                };

                                return @call(.always_inline, cb, .{
                                    common.userdataValue(Userdata, ud),
                                    l_inner,
                                    c_inner,
                                    initFd(op.fd),
                                    user_result,
                                });
                            }
                        }).callback,
                    };
                },
                .kqueue => @compileError("recvmsgWithPool is Linux-only"),
            }
            loop.add(c);
        }

        test {
            _ = TCPTests(xev, Self);
        }
    };
}

fn TCPTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "TCP: Stream decls" {
            if (!@hasDecl(Impl, "S")) return;
            const Stream = Impl.S;
            inline for (@typeInfo(Stream).@"struct".decls) |decl| {
                const Decl = @TypeOf(@field(Stream, decl.name));
                if (Decl == void) continue;
                if (!@hasDecl(Impl, decl.name)) {
                    @compileError("missing decl: " ++ decl.name);
                }
            }
        }

        test "TCP: accept/connect/send/recv/close" {
            const testing = std.testing;

            var tpool = ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Choose random available port (Zig #14907)
            var address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const server = try Impl.init(address);

            // Bind and listen
            try server.bind(address);
            try server.listen(1);

            // Retrieve bound port and initialize client
            var sock_len = address.getOsSockLen();
            const fd = server.fd;
            try posix.getsockname(fd, &address.any, &sock_len);
            const client = try Impl.init(address);

            //const address = try std.net.Address.parseIp4("127.0.0.1", 3132);
            //var server = try Impl.init(address);
            //var client = try Impl.init(address);

            // Completions we need
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;

            // Accept
            var server_conn: ?Impl = null;
            server.accept(&loop, &c_accept, ?Impl, &server_conn, (struct {
                fn callback(
                    ud: ?*?Impl,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.AcceptError!Impl,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Connect
            var connected: bool = false;
            client.connect(&loop, &c_connect, address.in, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.ConnectError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait for the connection to be established
            try loop.run(.until_done);
            try testing.expect(server_conn != null);
            try testing.expect(connected);

            // Close the server
            var server_closed = false;
            server.close(&loop, &c_accept, bool, &server_closed, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);
            try loop.run(.until_done);
            try testing.expect(server_closed);

            // Send
            var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
            client.write(&loop, &c_connect, .{ .slice = &send_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    c: *xev.Completion,
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    _ = c;
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Receive
            var recv_buf: [128]u8 = undefined;
            var recv_len: usize = 0;
            server_conn.?.read(&loop, &c_accept, .{ .slice = &recv_buf }, usize, &recv_len, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Wait for the send/receive
            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, &send_buf, recv_buf[0..recv_len]);

            // Close
            server_conn.?.close(&loop, &c_accept, ?Impl, &server_conn, (struct {
                fn callback(
                    ud: ?*?Impl,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = null;
                    return .disarm;
                }
            }).callback);
            client.close(&loop, &c_connect, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = false;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(server_conn == null);
            try testing.expect(!connected);
            try testing.expect(server_closed);
        }

        // Potentially flaky - this test could hang if the sender is unable to
        // write everything to the socket for whatever reason
        // (e.g. incorrectly sized buffer on the receiver side), or if the
        // receiver is trying to receive while sender has nothing left to send.
        //
        // Overview:
        // 1. Set up server and client sockets
        // 2. connect & accept, set SO_SNDBUF to 8kB on the client
        // 3. Try to send 1MB buffer from client to server without queuing, this _should_ fail
        //    and theoretically send <= 8kB, but in practice, it seems to write ~32kB.
        //    Asserts that <= 100kB was written
        // 4. Set up a queued write with the remaining buffer, shutdown() the socket afterwards
        // 5. Set up a receiver that loops until it receives the entire buffer
        // 6. Assert send_buf == recv_buf
        test "TCP: Queued writes" {
            const testing = std.testing;

            var tpool = ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Choose random available port (Zig #14907)
            var address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const server = try Impl.init(address);

            // Bind and listen
            try server.bind(address);
            try server.listen(1);

            // Retrieve bound port and initialize client
            var sock_len = address.getOsSockLen();
            try posix.getsockname(server.fd, &address.any, &sock_len);
            const client = try Impl.init(address);

            // Completions we need
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;

            // Accept
            var server_conn: ?Impl = null;
            server.accept(&loop, &c_accept, ?Impl, &server_conn, (struct {
                fn callback(
                    ud: ?*?Impl,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.AcceptError!Impl,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Connect
            var connected: bool = false;
            client.connect(&loop, &c_connect, address.in, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.ConnectError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait for the connection to be established
            try loop.run(.until_done);
            try testing.expect(server_conn != null);
            try testing.expect(connected);

            // Close the server
            var server_closed = false;
            server.close(&loop, &c_accept, bool, &server_closed, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);
            try loop.run(.until_done);
            try testing.expect(server_closed);

            // Unqueued send - Limit send buffer to 8kB, this should force partial writes.
            try posix.setsockopt(
                client.fd,
                posix.SOL.SOCKET,
                posix.SO.SNDBUF,
                &std.mem.toBytes(@as(c_int, 8192)),
            );

            const send_buf = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 0 } ** 100_000;
            var sent_unqueued: usize = 0;

            // First we try to send the whole 1MB buffer in one write operation, this _should_ result
            // in a partial write.
            client.write(&loop, &c_connect, .{ .slice = &send_buf }, usize, &sent_unqueued, (struct {
                fn callback(
                    sent_unqueued_inner: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    sent_unqueued_inner.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Make sure that we sent a small fraction of the buffer
            try loop.run(.until_done);
            // SO_SNDBUF doesn't seem to be respected exactly, sent_unqueued will often be ~32kB
            // even though SO_SNDBUF was set to 8kB
            try testing.expect(sent_unqueued < (send_buf.len / 10));

            // Set up queued write
            var w_queue = xev.WriteQueue{};
            var wr_send: xev.WriteRequest = undefined;
            var sent_queued: usize = 0;
            const queued_slice = send_buf[sent_unqueued..];
            client.queueWrite(&loop, &w_queue, &wr_send, .{ .slice = queued_slice }, usize, &sent_queued, (struct {
                fn callback(
                    sent_queued_inner: ?*usize,
                    l: *xev.Loop,
                    c: *xev.Completion,
                    tcp: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    sent_queued_inner.?.* = r catch unreachable;

                    tcp.shutdown(l, c, void, null, (struct {
                        fn callback(
                            _: ?*void,
                            _: *xev.Loop,
                            _: *xev.Completion,
                            _: Impl,
                            _: xev.ShutdownError!void,
                        ) xev.CallbackAction {
                            return .disarm;
                        }
                    }).callback);

                    return .disarm;
                }
            }).callback);

            // Set up receiver which is going to keep reading until it reads the full
            // send buffer
            const Receiver = struct {
                loop: *xev.Loop,
                conn: Impl,
                completion: xev.Completion = .{},
                buf: [send_buf.len]u8 = undefined,
                bytes_read: usize = 0,

                pub fn read(receiver: *@This()) void {
                    if (receiver.bytes_read == receiver.buf.len) return;

                    const read_buf = xev.ReadBuffer{
                        .slice = receiver.buf[receiver.bytes_read..],
                    };
                    receiver.conn.read(receiver.loop, &receiver.completion, read_buf, @This(), receiver, readCb);
                }

                pub fn readCb(
                    receiver_opt: ?*@This(),
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    var receiver = receiver_opt.?;
                    const n_bytes = r catch unreachable;

                    receiver.bytes_read += n_bytes;
                    if (receiver.bytes_read < send_buf.len) {
                        receiver.read();
                    }

                    return .disarm;
                }
            };
            var receiver = Receiver{
                .loop = &loop,
                .conn = server_conn.?,
            };
            receiver.read();

            // Wait for the send/receive
            try loop.run(.until_done);
            try testing.expectEqualSlices(u8, &send_buf, receiver.buf[0..receiver.bytes_read]);
            try testing.expect(send_buf.len == sent_unqueued + sent_queued);

            // Close
            server_conn.?.close(&loop, &c_accept, ?Impl, &server_conn, (struct {
                fn callback(
                    ud: ?*?Impl,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = null;
                    return .disarm;
                }
            }).callback);
            client.close(&loop, &c_connect, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = false;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(server_conn == null);
            try testing.expect(!connected);
            try testing.expect(server_closed);
        }

        test "TCP: recvWithPool basic" {
            // Skip if recvWithPool is not available (dynamic API)
            if (!@hasDecl(Impl, "recvWithPool")) return;

            const testing = std.testing;

            var tpool = ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create buffer pool
            var pool = try xev.BufferPool.init(testing.allocator, .{ .count = 16, .size = 1024 });
            defer pool.deinit();
            try pool.register(&loop);
            defer pool.unregister(&loop);

            // Choose random available port
            var address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const server = try Impl.init(address);
            try server.bind(address);
            try server.listen(1);

            // Get bound port and create client
            var sock_len = address.getOsSockLen();
            const fd = server.fd;
            try posix.getsockname(fd, &address.any, &sock_len);
            const client = try Impl.init(address);

            // Accept/Connect
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;
            var server_conn: ?Impl = null;
            var connected: bool = false;

            server.accept(&loop, &c_accept, ?Impl, &server_conn, (struct {
                fn callback(
                    ud: ?*?Impl,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.AcceptError!Impl,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            client.connect(&loop, &c_connect, address.in, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.ConnectError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(server_conn != null);
            try testing.expect(connected);

            // Close the server (not needed for recv)
            var server_closed = false;
            server.close(&loop, &c_accept, bool, &server_closed, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);
            try loop.run(.until_done);

            // Send data from client
            const send_buf = "Hello, BufferPool!";
            client.write(&loop, &c_connect, .{ .slice = send_buf }, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            // Receive with pool
            var recv_data: ?[]u8 = null;
            var recv_c: xev.Completion = undefined;
            server_conn.?.recvWithPool(&loop, &recv_c, &pool, ?[]u8, &recv_data, (struct {
                fn callback(
                    ud: ?*?[]u8,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.RecvPoolError!xev.BufferPool.Recv,
                ) xev.CallbackAction {
                    if (r) |recv| {
                        // Copy the data since we'll release the buffer
                        const alloc = testing.allocator;
                        ud.?.* = alloc.dupe(u8, recv.data()) catch null;
                        recv.release();
                    } else |_| {
                        ud.?.* = null;
                    }
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);

            // Verify received data
            if (recv_data) |data| {
                defer testing.allocator.free(data);
                try testing.expectEqualSlices(u8, send_buf, data);
            } else {
                // On io_uring, recvWithPool requires more setup
                // For now, just verify it doesn't crash
                if (xev.backend != .io_uring) {
                    return error.TestUnexpectedResult;
                }
            }

            // Cleanup
            server_conn.?.close(&loop, &c_accept, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.CloseError!void,
                ) xev.CallbackAction {
                    return .disarm;
                }
            }).callback);
            client.close(&loop, &c_connect, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.CloseError!void,
                ) xev.CallbackAction {
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
        }

        test "TCP: recvWithPoolMultishot" {
            if (!@hasDecl(Impl, "recvWithPoolMultishot")) return;
            // Multishot recv is only supported on io_uring
            if (xev.backend != .io_uring) return;

            const testing = std.testing;

            var tpool = ThreadPool.init(.{});
            defer tpool.deinit();
            defer tpool.shutdown();
            var loop = try xev.Loop.init(.{ .thread_pool = &tpool });
            defer loop.deinit();

            // Create buffer pool
            var pool = try xev.BufferPool.init(testing.allocator, .{ .count = 16, .size = 1024 });
            defer pool.deinit();
            try pool.register(&loop);
            defer pool.unregister(&loop);

            // Choose random available port
            var address = try std.net.Address.parseIp4("127.0.0.1", 0);
            const server = try Impl.init(address);
            try server.bind(address);
            try server.listen(1);

            // Get bound port and create client
            var sock_len = address.getOsSockLen();
            try posix.getsockname(server.fd, &address.any, &sock_len);
            const client = try Impl.init(address);

            // Accept/Connect
            var c_accept: xev.Completion = undefined;
            var c_connect: xev.Completion = undefined;
            var server_conn: ?Impl = null;
            var connected: bool = false;

            server.accept(&loop, &c_accept, ?Impl, &server_conn, (struct {
                fn callback(
                    ud: ?*?Impl,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.AcceptError!Impl,
                ) xev.CallbackAction {
                    ud.?.* = r catch unreachable;
                    return .disarm;
                }
            }).callback);

            client.connect(&loop, &c_connect, address.in, bool, &connected, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.ConnectError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
            try testing.expect(server_conn != null);
            try testing.expect(connected);

            // Close the listening server
            var server_closed = false;
            server.close(&loop, &c_accept, bool, &server_closed, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);
            try loop.run(.until_done);

            // Track multishot recv completions
            const State = struct {
                recv_count: usize = 0,
                total_bytes: usize = 0,
                combined: [12]u8 = undefined, // "msg1" + "msg2" + "msg3" = 12
                got_eof: bool = false,
            };
            var state = State{};

            // Start multishot recv before sending data
            var recv_c: xev.Completion = undefined;
            server_conn.?.recvWithPoolMultishot(&loop, &recv_c, &pool, State, &state, (struct {
                fn callback(
                    ud: ?*State,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    r: xev.RecvPoolError!xev.BufferPool.Recv,
                ) xev.CallbackAction {
                    const s = ud.?;
                    if (r) |recv| {
                        const d = recv.data();
                        @memcpy(s.combined[s.total_bytes..][0..d.len], d);
                        s.total_bytes += d.len;
                        s.recv_count += 1;
                        recv.release();
                        return .rearm;
                    } else |_| {
                        // EOF or error terminates multishot
                        s.got_eof = true;
                        return .disarm;
                    }
                }
            }).callback);

            // Send data directly via posix (avoids event loop contention with multishot)
            const send_data = "msg1msg2msg3";
            _ = try posix.send(client.fd, send_data, 0);

            // Close client to trigger EOF on the receiver, which disarms multishot
            posix.close(client.fd);

            // Run until multishot recv gets EOF and disarms
            try loop.run(.until_done);

            // Verify we received all data
            try testing.expect(state.recv_count >= 1);
            try testing.expect(state.got_eof);
            try testing.expectEqual(@as(usize, 12), state.total_bytes);
            try testing.expectEqualSlices(u8, send_data, state.combined[0..state.total_bytes]);

            // Cleanup — client already closed above, just close server conn
            server_conn.?.close(&loop, &c_accept, void, null, (struct {
                fn callback(
                    _: ?*void,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    _: Impl,
                    _: xev.CloseError!void,
                ) xev.CallbackAction {
                    return .disarm;
                }
            }).callback);

            try loop.run(.until_done);
        }
    };
}
