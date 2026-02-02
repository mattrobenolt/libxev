const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

/// BufferPool provides efficient buffer management for receive operations.
/// On io_uring (kernel 6.0+), uses IORING_REGISTER_PBUF_RING for kernel-managed
/// provided buffer rings. On kqueue, falls back to a user-space lock-free pool.
pub fn BufferPool(comptime xev: type) type {
    return struct {
        const Self = @This();

        pub const Config = struct {
            /// Number of buffers in the pool. Must be a power of 2 for io_uring.
            count: u16 = 64,
            /// Size of each buffer in bytes.
            size: u32 = 4096,
            /// Buffer group ID (io_uring only). Must be unique per loop.
            group_id: u16 = 0,
        };

        pub const Buffer = struct {
            data: []u8,
            pool: *Self,
            buffer_id: u16,

            /// Release the buffer back to the pool for reuse.
            pub fn release(self: Buffer) void {
                self.pool.releaseBuffer(self.buffer_id);
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
        impl: switch (xev.backend) {
            .io_uring => IoUringImpl,
            .kqueue => KqueueImpl,
        },

        config: Config,
        allocator: Allocator,

        /// Initialize a new buffer pool.
        pub fn init(allocator: Allocator, config: Config) !Self {
            // Validate config
            if (config.count == 0) return error.InvalidCount;
            if (config.size == 0) return error.InvalidSize;

            const impl = switch (xev.backend) {
                .io_uring => try IoUringImpl.init(allocator, config),
                .kqueue => try KqueueImpl.init(allocator, config),
            };

            return .{
                .impl = impl,
                .config = config,
                .allocator = allocator,
            };
        }

        /// Register the buffer pool with the event loop.
        /// For io_uring, this registers the buffer ring with the kernel.
        /// For kqueue, this is a no-op.
        pub fn register(self: *Self, loop: *xev.Loop) !void {
            switch (xev.backend) {
                .io_uring => try self.impl.register(&loop.ring, self.config),
                .kqueue => {}, // No-op for kqueue
            }
        }

        /// Unregister the buffer pool from the event loop.
        pub fn unregister(self: *Self, loop: *xev.Loop) void {
            switch (xev.backend) {
                .io_uring => self.impl.unregister(&loop.ring, self.config),
                .kqueue => {}, // No-op for kqueue
            }
        }

        /// Deinitialize the buffer pool and free all memory.
        pub fn deinit(self: *Self) void {
            switch (xev.backend) {
                .io_uring => self.impl.deinit(self.allocator),
                .kqueue => self.impl.deinit(self.allocator),
            }
        }

        /// Acquire a buffer from the pool. Returns null if no buffers available.
        /// For io_uring, buffers are typically acquired by the kernel during recv.
        /// This method is primarily for kqueue or manual buffer management.
        pub fn acquire(self: *Self) ?Buffer {
            switch (xev.backend) {
                .io_uring => {
                    // For io_uring, buffers are managed by the kernel.
                    // This is used for fallback or manual operations.
                    const buffer_id = self.impl.acquireFromUserPool() orelse return null;
                    return .{
                        .data = self.impl.getBuffer(buffer_id, self.config.size),
                        .pool = self,
                        .buffer_id = buffer_id,
                    };
                },
                .kqueue => {
                    const buffer_id = self.impl.acquire() orelse return null;
                    return .{
                        .data = self.impl.getBuffer(buffer_id, self.config.size),
                        .pool = self,
                        .buffer_id = buffer_id,
                    };
                },
            }
        }

        /// Release a buffer back to the pool.
        pub fn releaseBuffer(self: *Self, buffer_id: u16) void {
            switch (xev.backend) {
                .io_uring => self.impl.releaseToUserPool(buffer_id),
                .kqueue => self.impl.release(buffer_id),
            }
        }

        /// Get a buffer by ID and convert a CQE result to a Recv.
        /// Used internally by recv_pool operations.
        pub fn getRecvFromResult(self: *Self, buffer_id: u16, bytes_read: usize) Recv {
            const buffer_data = switch (xev.backend) {
                .io_uring => self.impl.getBuffer(buffer_id, self.config.size),
                .kqueue => self.impl.getBuffer(buffer_id, self.config.size),
            };
            return .{
                .buffer = .{
                    .data = buffer_data,
                    .pool = self,
                    .buffer_id = buffer_id,
                },
                .n = bytes_read,
            };
        }

        /// io_uring implementation using provided buffer rings.
        const IoUringImpl = struct {
            /// The provided buffer ring registered with io_uring.
            buf_ring: ?linux.IoUring.BufferGroup = null,

            /// User-space free list for manual acquire/release.
            /// This is a backup for when we need to acquire buffers manually.
            user_free_list: std.atomic.Value(u32),
            user_free_nodes: []std.atomic.Value(u16),

            /// Backing memory for all buffers.
            buffer_memory: []u8,

            fn init(allocator: Allocator, config: Config) !IoUringImpl {
                const total_size = @as(usize, config.count) * @as(usize, config.size);
                const buffer_memory = try allocator.alloc(u8, total_size);
                errdefer allocator.free(buffer_memory);

                // Initialize user-space free list for manual operations
                const user_free_nodes = try allocator.alloc(std.atomic.Value(u16), config.count);
                errdefer allocator.free(user_free_nodes);

                // Build linked list: each node points to next
                for (0..config.count) |i| {
                    const idx: u16 = @intCast(i);
                    if (i + 1 < config.count) {
                        user_free_nodes[i] = .{ .raw = idx + 1 };
                    } else {
                        user_free_nodes[i] = .{ .raw = std.math.maxInt(u16) }; // End marker
                    }
                }

                return .{
                    .buf_ring = null,
                    .user_free_list = .{ .raw = 0 }, // Head points to first buffer
                    .user_free_nodes = user_free_nodes,
                    .buffer_memory = buffer_memory,
                };
            }

            fn register(self: *IoUringImpl, ring: *linux.IoUring, config: Config) !void {
                if (self.buf_ring != null) return error.AlreadyRegistered;

                self.buf_ring = try linux.IoUring.BufferGroup.init(
                    ring,
                    config.group_id,
                    self.buffer_memory,
                    config.size,
                    config.count,
                );
            }

            fn unregister(self: *IoUringImpl, ring: *linux.IoUring, config: Config) void {
                if (self.buf_ring) |*bg| {
                    bg.deinit(ring, config.group_id);
                    self.buf_ring = null;
                }
            }

            fn deinit(self: *IoUringImpl, allocator: Allocator) void {
                allocator.free(self.user_free_nodes);
                allocator.free(self.buffer_memory);
            }

            fn getBuffer(self: *IoUringImpl, buffer_id: u16, buffer_size: u32) []u8 {
                const start = @as(usize, buffer_id) * @as(usize, buffer_size);
                return self.buffer_memory[start..][0..buffer_size];
            }

            /// Put a buffer back into the kernel's buffer ring after use.
            pub fn putBuffer(self: *IoUringImpl, buffer_id: u16, buffer_size: u32) void {
                if (self.buf_ring) |*bg| {
                    const buf = self.getBuffer(buffer_id, buffer_size);
                    bg.put(buffer_id, buf);
                }
            }

            // User-space pool operations for manual acquire/release
            fn acquireFromUserPool(self: *IoUringImpl) ?u16 {
                while (true) {
                    const head = self.user_free_list.load(.acquire);
                    if (head == std.math.maxInt(u16)) return null; // Pool exhausted

                    // Clamp to valid range to avoid out of bounds
                    if (head >= self.user_free_nodes.len) return null;

                    const next = self.user_free_nodes[head].load(.acquire);
                    if (self.user_free_list.cmpxchgWeak(head, next, .release, .acquire)) |_| {
                        continue; // CAS failed, retry
                    }
                    return head;
                }
            }

            fn releaseToUserPool(self: *IoUringImpl, buffer_id: u16) void {
                while (true) {
                    const head = self.user_free_list.load(.acquire);
                    self.user_free_nodes[buffer_id].store(head, .release);
                    if (self.user_free_list.cmpxchgWeak(buffer_id, head, .release, .acquire)) |_| {
                        continue; // CAS failed, retry
                    }
                    return;
                }
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

        test "BufferPool: acquire/release cycle" {
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

        test "BufferPool: pool exhaustion returns null" {
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

        test "BufferPool: buffer data is accessible" {
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
