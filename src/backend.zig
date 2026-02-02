const builtin = @import("builtin");

/// The backend types.
pub const Backend = enum {
    io_uring,
    kqueue,

    /// Returns a recommend default backend from inspecting the system.
    pub fn default() Backend {
        return switch (builtin.os.tag) {
            .linux => .io_uring,
            .macos => .kqueue,
            else => {
                @compileLog(builtin.os);
                @compileError("no default backend for this target");
            },
        };
    }

    /// Candidate backends for this platform in priority order.
    pub fn candidates() []const Backend {
        return switch (builtin.os.tag) {
            .linux => &.{.io_uring},
            .macos => &.{.kqueue},
            else => {
                @compileLog(builtin.os);
                @compileError("no candidate backends for this target");
            },
        };
    }

    /// Returns the Api (return value of Xev) for the given backend type.
    pub fn Api(comptime self: Backend) type {
        return switch (self) {
            .io_uring => @import("main.zig").IO_Uring,
            .kqueue => @import("main.zig").Kqueue,
        };
    }
};
