const std = @import("std");
const xev = @import("xev");

/// A simple TCP echo server using BufferPool for efficient buffer management.
///
/// This example demonstrates:
/// - Creating and registering a BufferPool with the event loop
/// - Using recvWithPool for zero-copy receives
/// - Proper buffer lifecycle management
///
/// Run with: zig build && ./zig-out/bin/buffer_pool_echo
/// Test with: echo "hello" | nc localhost 3000

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the event loop
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Create a buffer pool with 64 buffers of 4KB each
    var pool = try xev.BufferPool.init(allocator, .{
        .count = 64,
        .size = 4096,
    });
    defer pool.deinit();

    // Register the pool with the loop (required for io_uring kernel buffer rings)
    try pool.register(&loop);
    defer pool.unregister(&loop);

    // Create and bind the server socket
    const address = try std.net.Address.parseIp4("127.0.0.1", 3000);
    const server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(128);

    std.debug.print("Echo server listening on 127.0.0.1:3000\n", .{});
    std.debug.print("Test with: echo 'hello' | nc localhost 3000\n", .{});

    // Create context for managing connections
    var ctx = Context{
        .allocator = allocator,
        .pool = &pool,
        .server = server,
    };

    // Start accepting connections
    var accept_completion: xev.Completion = undefined;
    server.accept(&loop, &accept_completion, Context, &ctx, acceptCallback);

    // Run the event loop
    try loop.run(.until_done);
}

const Context = struct {
    allocator: std.mem.Allocator,
    pool: *xev.BufferPool,
    server: xev.TCP,
};

const Connection = struct {
    socket: xev.TCP,
    pool: *xev.BufferPool,
    recv_completion: xev.Completion = undefined,
    send_completion: xev.Completion = undefined,
    // Buffer for echoing back - we copy data here since the pool buffer
    // needs to be released promptly
    echo_buf: [4096]u8 = undefined,
    echo_len: usize = 0,
};

fn acceptCallback(
    ctx: ?*Context,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const context = ctx.?;

    if (result) |client| {
        std.debug.print("New connection accepted\n", .{});

        // Allocate connection state
        const conn = context.allocator.create(Connection) catch {
            std.debug.print("Failed to allocate connection\n", .{});
            client.close(loop, c, void, null, closeCallback);
            return .disarm;
        };

        conn.* = .{
            .socket = client,
            .pool = context.pool,
        };

        // Start receiving with buffer pool
        client.recvWithPool(
            loop,
            &conn.recv_completion,
            context.pool,
            Connection,
            conn,
            recvCallback,
        );
    } else |err| {
        std.debug.print("Accept error: {}\n", .{err});
    }

    // Rearm to accept more connections
    context.server.accept(loop, c, Context, context, acceptCallback);
    return .disarm;
}

fn recvCallback(
    conn: ?*Connection,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    result: xev.RecvPoolError!xev.BufferPool.Recv,
) xev.CallbackAction {
    const connection = conn.?;

    if (result) |recv| {
        const data = recv.data();
        std.debug.print("Received {} bytes: {s}\n", .{ data.len, data });

        // Copy data to echo buffer before releasing pool buffer
        const copy_len = @min(data.len, connection.echo_buf.len);
        @memcpy(connection.echo_buf[0..copy_len], data[0..copy_len]);
        connection.echo_len = copy_len;

        // Release the buffer back to the pool
        recv.release();

        // Echo the data back
        connection.socket.write(
            loop,
            &connection.send_completion,
            .{ .slice = connection.echo_buf[0..connection.echo_len] },
            Connection,
            connection,
            sendCallback,
        );
    } else |err| {
        if (err == error.EOF) {
            std.debug.print("Client disconnected\n", .{});
        } else {
            std.debug.print("Receive error: {}\n", .{err});
        }
        // Close the connection
        connection.socket.close(loop, &connection.recv_completion, Connection, connection, connectionCloseCallback);
    }

    return .disarm;
}

fn sendCallback(
    conn: ?*Connection,
    loop: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    const connection = conn.?;

    if (result) |bytes_sent| {
        std.debug.print("Echoed {} bytes\n", .{bytes_sent});

        // Continue receiving
        connection.socket.recvWithPool(
            loop,
            &connection.recv_completion,
            connection.pool,
            Connection,
            connection,
            recvCallback,
        );
    } else |err| {
        std.debug.print("Send error: {}\n", .{err});
        connection.socket.close(loop, &connection.recv_completion, Connection, connection, connectionCloseCallback);
    }

    return .disarm;
}

fn connectionCloseCallback(
    conn: ?*Connection,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    // In a real application, you'd free the Connection here using the allocator
    // For this example, we just leak it since we don't have access to the allocator
    _ = conn;
    std.debug.print("Connection closed\n", .{});
    return .disarm;
}

fn closeCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    return .disarm;
}
