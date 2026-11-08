//! Minimal std.http server, used as an instrumentation target.
//!
//! Deliberately shaped for probing: `handleRequest` is its own named
//! function taking the request by pointer, so there is something for a
//! uprobe to attach to.
//!
//! Build:   zig build-exe examples/http-minimal.zig
//! Run:     ./http-minimal          (listens on 127.0.0.1:8080)
//! Poke:    curl -v http://127.0.0.1:8080/hello

const std = @import("std");
const Io = std.Io;

const listen_port = 8080;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const address = Io.net.IpAddress.parse("127.0.0.1", listen_port) catch unreachable;
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.socket.close(io);

    std.log.info("listening on http://127.0.0.1:{d}/", .{tcp_server.socket.address.getPort()});

    while (true) {
        const stream = try tcp_server.accept(io);
        serveConnection(io, stream);
    }
}

/// Owns one client connection for its whole lifetime: parses requests off it
/// until the peer goes away, dispatching each to `handleRequest`.
fn serveConnection(io: Io, stream: Io.net.Stream) void {
    defer stream.close(io);

    var recv_buffer: [4000]u8 = undefined;
    var send_buffer: [4000]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);

    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.log.err("closing connection: {t}", .{err});
                return;
            },
        };
        handleRequest(&request) catch |err| {
            std.log.err("failed to serve {s}: {t}", .{ request.head.target, err });
            return;
        };
    }
}

/// The probe target. One request in, one fixed response out.
fn handleRequest(request: *std.http.Server.Request) !void {
    std.log.info("{t} {s}", .{ request.head.method, request.head.target });

    try request.respond("hello from zig\n", .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain" },
        },
    });
}
