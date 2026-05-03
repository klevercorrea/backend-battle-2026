//! Async HTTP/1.1 server with comptime route dispatch.
//! Supports both Unix domain sockets (for HAProxy) and TCP.
//! This file handles ONLY transport concerns: accept, parse, route, respond.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const fs = std.fs;

const ctx_mod = @import("context.zig");
const handlers = @import("handlers.zig");
const resp = @import("responses.zig");

const AppContext = ctx_mod.AppContext;
const Method = ctx_mod.Method;
const Request = ctx_mod.Request;

const log = std.log.scoped(.server);

/// Gold Standard Router: Comptime-based path dispatch.
const Router = struct {
    const Handler = *const fn (io: Io, stream: net.Stream, ctx: *const AppContext, req: Request) anyerror!void;

    const Route = struct {
        method: Method,
        path: []const u8,
        handler: Handler,
    };

    const routes = [_]Route{
        .{ .method = .GET, .path = "/ready", .handler = handlers.handleReady },
        .{ .method = .POST, .path = "/fraud-score", .handler = handlers.handleFraudScore },
    };

    fn dispatch(method: Method, path: []const u8) ?Handler {
        inline for (routes) |route| {
            if (route.method == method and std.mem.eql(u8, route.path, path)) {
                return route.handler;
            }
        }
        return null;
    }
};

/// Starts the HTTP server. If `socket_path` is provided, listens on a Unix
/// domain socket; otherwise falls back to TCP port 9999.
pub fn run(io: Io, ctx: *const AppContext, socket_path: ?[]const u8) !void {
    var server: net.Server = if (socket_path) |path| s: {
        // Clean up previous socket if it exists
        std.posix.unlink(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const addr = try net.UnixAddress.init(path);
        log.info("Listening on Unix Domain Socket: {s}", .{path});
        const s = try addr.listen(io, .{});

        // Ensure the load balancer (HAProxy) can read/write the socket.
        try std.posix.fchmodat(std.os.linux.AT.FDCWD, path, 0o666, 0);

        break :s s;
    } else s: {
        const addr = try net.IpAddress.parse("0.0.0.0", 9999);
        log.info("Listening on TCP :9999", .{});
        break :s try addr.listen(io, .{});
    };
    defer server.deinit(io);

    var group = Io.Group{
        .token = std.atomic.Value(?*anyopaque).init(null),
        .state = 0,
    };

    while (true) {
        const stream = try server.accept(io);
        log.debug("Accepted connection", .{});
        group.async(io, handleConnection, .{ io, stream, ctx });
    }
}

fn handleConnection(io: Io, stream: net.Stream, ctx: *const AppContext) Io.Cancelable!void {
    handleConnectionInternal(io, stream, ctx) catch |err| {
        // Silently ignore expected network errors; log anything else.
        const name = @errorName(err);
        const is_expected = std.mem.eql(u8, name, "EndOfStream") or
            std.mem.eql(u8, name, "BrokenPipe") or
            std.mem.eql(u8, name, "ConnectionResetByPeer");
        if (!is_expected) {
            log.err("Error handling connection: {s}", .{name});
        }
    };
}

fn handleConnectionInternal(io: Io, stream: net.Stream, ctx: *const AppContext) !void {
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const r = &reader.interface;

    connection_loop: while (true) {
        // 1. Read Headers
        var header_end: ?usize = null;
        while (header_end == null) {
            r.fill(1) catch |err| {
                if (err == error.EndOfStream) return; // Normal closure
                return err;
            };
            const buffered = r.buffered();
            if (buffered.len == 0) return;
            header_end = std.mem.indexOf(u8, buffered, "\r\n\r\n");
            if (buffered.len == read_buffer.len and header_end == null) return error.HeadersTooLarge;
        }

        const headers_raw = r.buffered()[0..header_end.?];
        const body_start = header_end.? + 4;

        // 2. Parse basic request info
        var line_it = std.mem.tokenizeSequence(u8, headers_raw, "\r\n");
        const first_line = line_it.next() orelse return error.InvalidRequest;
        var part_it = std.mem.tokenizeScalar(u8, first_line, ' ');
        const method_raw = part_it.next() orelse return error.InvalidRequest;
        const path_raw = part_it.next() orelse return error.InvalidRequest;

        // Safety: Copy path to stack buffer as reader.take() invalidates headers_raw
        var path_buf: [128]u8 = undefined;
        const path_len = @min(path_raw.len, path_buf.len);
        @memcpy(path_buf[0..path_len], path_raw[0..path_len]);
        const path = path_buf[0..path_len];

        const method: Method = if (std.mem.eql(u8, method_raw, "GET")) .GET else if (std.mem.eql(u8, method_raw, "POST")) .POST else .UNKNOWN;

        // 3. Match Handler & determine Keep-Alive
        const handler = Router.dispatch(method, path);
        var body_len: usize = 0;
        var should_close = false;
        while (line_it.next()) |line| {
            if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "Content-Length:")) {
                body_len = try std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " "), 10);
            } else if (line.len > 11 and std.ascii.eqlIgnoreCase(line[0..11], "Connection:")) {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[11..], " "), "close")) should_close = true;
            }
        }

        // 4. Consume headers and body from reader
        _ = try r.take(body_start);
        const body = try r.take(body_len);

        // 5. Execute handler
        if (handler) |h| {
            h(io, stream, ctx, .{ .method = method, .path = path, .body = body }) catch |err| {
                log.err("Handler error: {any}", .{err});
                break :connection_loop;
            };
        } else {
            var w_buf: [256]u8 = undefined;
            var w = stream.writer(io, &w_buf);
            try w.interface.writeAll(resp.err_404);
            try w.interface.flush();
        }

        if (should_close) break :connection_loop;
    }
}
