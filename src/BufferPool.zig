const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;

/// BufferPool provides efficient buffer management for receive operations.
/// On io_uring (kernel 6.0+), uses IORING_REGISTER_PBUF_RING for kernel-managed
/// provided buffer rings. On kqueue, falls back to a user-space lock-free pool.
pub fn BufferPool(comptime xev: type) type {
    return struct {
        const Self = @This();

        const Impl = switch (xev.backend) {
            .io_uring => IoUringImpl,
            .kqueue => KqueueImpl,
        };

        pub const Config = struct {
            /// Number of buffers in the pool. Must be a power of 2 for io_uring.
            count: u16 = 64,
            /// Size of each buffer in bytes.
            size: u32 = 4096,
            /// Buffer group ID (io_uring only). Must be unique per loop.
            group_id: u16 = 0,
        };

        /// On io_uring, the CQE carries buffer flags needed for correct INC
        /// mode buffer lifecycle (BUF_MORE, res). On kqueue, this is void.
        const Cqe = if (xev.backend == .io_uring) linux.io_uring_cqe else void;

        pub const Buffer = struct {
            data: []u8,
            pool: *Self,
            buffer_id: u16,
            cqe: Cqe,

            /// Release the buffer back to the pool for reuse.
            pub fn release(self: Buffer) void {
                self.pool.releaseBuffer(self.buffer_id, self.cqe);
            }
        };

        pub const Recv = struct {
            buffer: Buffer,
            /// Number of bytes received into the buffer.
            n: usize,

            /// Returns the slice of data actually received.
            pub fn data(self: Recv) []u8 {
                return self.buffer.data[0..self.n];
            }

            /// Release the buffer back to the pool.
            pub fn release(self: Recv) void {
                self.buffer.release();
            }
        };

        /// Backend-specific implementation.
        impl: Impl,

        config: Config,
        allocator: Allocator,

        /// Initialize a new buffer pool.
        pub fn init(allocator: Allocator, config: Config) !Self {
            // Validate config
            if (config.count == 0) return error.InvalidCount;
            if (config.size == 0) return error.InvalidSize;

            return .{
                .impl = try Impl.init(allocator, config),
                .config = config,
                .allocator = allocator,
            };
        }

        /// Register the buffer pool with the event loop.
        /// For io_uring, this registers the buffer ring with the kernel.
        /// For kqueue, this is a no-op.
        pub fn register(self: *Self, loop: *xev.Loop) !void {
            switch (xev.backend) {
                .io_uring => try self.impl.register(&loop.ring, self.allocator, self.config),
                .kqueue => {}, // No-op for kqueue
            }
        }

        /// Unregister the buffer pool from the event loop.
        pub fn unregister(self: *Self, loop: *xev.Loop) void {
            _ = loop;
            switch (xev.backend) {
                .io_uring => self.impl.unregister(self.allocator),
                .kqueue => {}, // No-op for kqueue
            }
        }

        /// Deinitialize the buffer pool and free all memory.
        pub fn deinit(self: *Self) void {
            self.impl.deinit(self.allocator);
            self.* = undefined;
        }

        /// Acquire a buffer from the pool. Returns null if no buffers available.
        /// For io_uring, buffers are acquired by the kernel during recv operations,
        /// so this method is not supported and will return null.
        /// For kqueue, this acquires from the user-space pool.
        pub fn acquire(self: *Self) ?Buffer {
            switch (xev.backend) {
                // For io_uring, buffers are selected by the kernel during recv.
                // Manual acquire is not supported.
                .io_uring => return null,
                .kqueue => {
                    const buffer_id = self.impl.acquire() orelse return null;
                    return .{
                        .data = self.impl.getBuffer(buffer_id, self.config.size),
                        .pool = self,
                        .buffer_id = buffer_id,
                        .cqe = {},
                    };
                },
            }
        }

        /// Release a buffer back to the pool.
        pub fn releaseBuffer(self: *Self, buffer_id: u16, cqe: Cqe) void {
            switch (xev.backend) {
                .io_uring => self.impl.buf_group.?.put(cqe) catch unreachable,
                .kqueue => self.impl.release(buffer_id),
            }
        }

        /// Get a buffer by ID and convert a CQE result to a Recv.
        /// Used internally by recv_pool operations.
        ///
        /// On io_uring with INC mode, returns the full available buffer from the
        /// heads offset (not sliced to cqe.res). Callers needing only the received
        /// bytes should use `Recv.data()` which slices to `[0..n]`.
        pub fn getRecvFromResult(self: *Self, buffer_id: u16, bytes_read: usize, cqe: Cqe) Recv {
            const buf_data = switch (xev.backend) {
                .io_uring => blk: {
                    // Replicate get_by_id logic (private in std) to get the full
                    // available buffer, not sliced to cqe.res. This allows callers
                    // to reuse the buffer as scratch space (e.g. for TLS decryption).
                    const bg = self.impl.buf_group.?;
                    const pos = bg.buffer_size * buffer_id;
                    break :blk bg.buffers[pos .. pos + bg.buffer_size][bg.heads[buffer_id]..];
                },
                .kqueue => self.impl.getBuffer(buffer_id, self.config.size),
            };
            return .{
                .buffer = .{
                    .data = buf_data,
                    .pool = self,
                    .buffer_id = buffer_id,
                    .cqe = cqe,
                },
                .n = bytes_read,
            };
        }

        /// io_uring implementation using provided buffer rings (kernel 5.19+).
        /// Uses BufferGroup which registers a ring-mapped buffer with the kernel.
        const IoUringImpl = struct {
            /// The provided buffer ring registered with io_uring.
            /// Null until register() is called.
            buf_group: ?IoUring.BufferGroup = null,

            fn init(allocator: Allocator, config: Config) !IoUringImpl {
                _ = allocator;
                _ = config;
                // BufferGroup allocates its own memory on register()
                return .{ .buf_group = null };
            }

            fn register(self: *IoUringImpl, ring: *IoUring, allocator: Allocator, config: Config) !void {
                if (self.buf_group != null) return error.AlreadyRegistered;

                self.buf_group = try .init(
                    ring,
                    allocator,
                    config.group_id,
                    config.size,
                    config.count,
                );
            }

            fn unregister(self: *IoUringImpl, allocator: Allocator) void {
                if (self.buf_group) |*bg| {
                    bg.deinit(allocator);
                    self.buf_group = null;
                }
            }

            fn deinit(self: *IoUringImpl, allocator: Allocator) void {
                // If still registered, unregister first
                self.unregister(allocator);
            }
        };

        /// kqueue implementation using a user-space lock-free free-list.
        const KqueueImpl = struct {
            /// Atomic head of free list. Value is buffer_id or maxInt for empty.
            free_list_head: std.atomic.Value(u32),

            /// Next pointers for lock-free list. Each entry points to next free buffer.
            free_list_next: []std.atomic.Value(u16),

            /// Backing memory for all buffers.
            buffer_memory: []u8,

            fn init(allocator: Allocator, config: Config) !KqueueImpl {
                const total_size = @as(usize, config.count) * @as(usize, config.size);
                const buffer_memory = try allocator.alloc(u8, total_size);
                errdefer allocator.free(buffer_memory);

                const free_list_next = try allocator.alloc(std.atomic.Value(u16), config.count);
                errdefer allocator.free(free_list_next);

                // Build linked list: each node points to next
                for (0..config.count) |i| {
                    const idx: u16 = @intCast(i);
                    if (i + 1 < config.count) {
                        free_list_next[i] = .{ .raw = idx + 1 };
                    } else {
                        free_list_next[i] = .{ .raw = std.math.maxInt(u16) }; // End marker
                    }
                }

                return .{
                    .free_list_head = .{ .raw = 0 }, // Head points to first buffer
                    .free_list_next = free_list_next,
                    .buffer_memory = buffer_memory,
                };
            }

            fn deinit(self: *KqueueImpl, allocator: Allocator) void {
                allocator.free(self.free_list_next);
                allocator.free(self.buffer_memory);
            }

            fn getBuffer(self: *KqueueImpl, buffer_id: u16, buffer_size: u32) []u8 {
                const start = @as(usize, buffer_id) * @as(usize, buffer_size);
                return self.buffer_memory[start..][0..buffer_size];
            }

            /// Acquire a buffer from the free list. Returns null if pool exhausted.
            fn acquire(self: *KqueueImpl) ?u16 {
                while (true) {
                    const head = self.free_list_head.load(.acquire);
                    if (head == std.math.maxInt(u32)) return null; // Pool exhausted

                    // Use u16 portion of head
                    const head_id: u16 = @truncate(head);
                    if (head_id == std.math.maxInt(u16)) return null;

                    // Clamp to valid range
                    if (head_id >= self.free_list_next.len) return null;

                    const next = self.free_list_next[head_id].load(.acquire);
                    // Pack next into u32 (with ABA counter in high bits if needed)
                    const next_head: u32 = next;

                    if (self.free_list_head.cmpxchgWeak(head, next_head, .release, .acquire)) |_| {
                        continue; // CAS failed, retry
                    }
                    return head_id;
                }
            }

            /// Release a buffer back to the free list.
            fn release(self: *KqueueImpl, buffer_id: u16) void {
                assert(buffer_id < self.free_list_next.len);

                while (true) {
                    const head = self.free_list_head.load(.acquire);
                    const head_id: u16 = @truncate(head);
                    self.free_list_next[buffer_id].store(head_id, .release);

                    const new_head: u32 = buffer_id;
                    if (self.free_list_head.cmpxchgWeak(head, new_head, .release, .acquire)) |_| {
                        continue; // CAS failed, retry
                    }
                    return;
                }
            }
        };

        // Unit tests
        test "BufferPool: init/deinit" {
            const allocator = std.testing.allocator;
            var pool = try Self.init(allocator, .{ .count = 16, .size = 1024 });
            defer pool.deinit();
        }

        test "BufferPool: acquire/release cycle (kqueue only)" {
            // This test is for kqueue's user-space pool. On io_uring, acquire() returns null
            // because buffers are managed by the kernel.
            if (xev.backend == .io_uring) return;

            const allocator = std.testing.allocator;
            var pool = try Self.init(allocator, .{ .count = 4, .size = 256 });
            defer pool.deinit();

            // Acquire all buffers
            var buffers: [4]?Buffer = undefined;
            for (0..4) |i| {
                buffers[i] = pool.acquire();
                try std.testing.expect(buffers[i] != null);
            }

            // Pool should be exhausted
            try std.testing.expect(pool.acquire() == null);

            // Release one buffer
            buffers[0].?.release();

            // Should be able to acquire again
            const buf = pool.acquire();
            try std.testing.expect(buf != null);
            buf.?.release();

            // Release remaining buffers
            for (1..4) |i| {
                if (buffers[i]) |b| b.release();
            }
        }

        test "BufferPool: pool exhaustion returns null (kqueue only)" {
            // This test is for kqueue's user-space pool.
            if (xev.backend == .io_uring) return;

            const allocator = std.testing.allocator;
            var pool = try Self.init(allocator, .{ .count = 2, .size = 128 });
            defer pool.deinit();

            const b1 = pool.acquire();
            const b2 = pool.acquire();
            try std.testing.expect(b1 != null);
            try std.testing.expect(b2 != null);

            // Third acquire should fail
            try std.testing.expect(pool.acquire() == null);

            b1.?.release();
            b2.?.release();
        }

        test "BufferPool: buffer data is accessible (kqueue only)" {
            // This test is for kqueue's user-space pool.
            if (xev.backend == .io_uring) return;

            const allocator = std.testing.allocator;
            var pool = try Self.init(allocator, .{ .count = 2, .size = 64 });
            defer pool.deinit();

            const buf = pool.acquire().?;
            defer buf.release();

            // Write to buffer
            @memset(buf.data, 0xAB);
            try std.testing.expectEqual(@as(u8, 0xAB), buf.data[0]);
            try std.testing.expectEqual(@as(usize, 64), buf.data.len);
        }
    };
}

test {
    // Run tests for the default backend
    const xev = @import("main.zig");
    _ = BufferPool(xev);
}
