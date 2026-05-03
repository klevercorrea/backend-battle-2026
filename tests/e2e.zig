//! E2E integration tests for the HTTP server.
//! Spins up a full server with mock data and validates endpoint behavior.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const core = @import("core");
const engine = @import("engine");
const http = @import("http");

const testing = std.testing;

test "E2E: server responds correctly to valid and invalid requests" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Mock AppContext
    const n_test = engine.vector_dim; // Use vector_dim as convenient test dataset size
    var mcc_risk = std.StringHashMap(f64).init(allocator);
    defer mcc_risk.deinit();

    const mock_data = try allocator.alignedAlloc(f32, .@"64", n_test * engine.vector_dim);
    defer allocator.free(mock_data);
    @memset(mock_data, 0);

    const mock_labels = try allocator.alloc(u8, n_test);
    defer allocator.free(mock_labels);
    @memset(mock_labels, 0);

    const ctx = http.AppContext{
        .dataset = engine.SoADataset.init(mock_data, n_test),
        .index = .{
            .centroids = [_][engine.vector_dim]f32{[_]f32{0} ** engine.vector_dim} ** engine.k_clusters,
            .offsets = [_]u32{0} ** engine.k_clusters,
            .lengths = [_]u32{ n_test, 0, 0, 0, 0, 0 },
        },
        .labels = mock_labels.ptr,
        .norm_constants = .{
            .max_amount = 10000,
            .max_installments = 12,
            .amount_vs_avg_ratio = 10,
            .max_minutes = 1440,
            .max_km = 1000,
            .max_tx_count_24h = 20,
            .max_merchant_avg_amount = 10000,
        },
        .mcc_risk = mcc_risk,
    };

    // 2. Start server in a background thread
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn runServer(i: Io, c: *const http.AppContext) void {
            http.run(i, c, null) catch |err| {
                if (err != error.Canceled) {
                    // std.debug.print("Server error: {any}\n", .{err});
                }
            };
        }
    }.runServer, .{ io, &ctx });

    // Give it a moment to start
    try io.sleep(Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .real);

    // 3. Client: Send requests
    const addr = try net.IpAddress.parse("127.0.0.1", 9999);

    {
        // Test /ready
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var w_buf: [256]u8 = undefined;
        var w = stream.writer(io, &w_buf);
        try w.interface.writeAll("GET /ready HTTP/1.1\r\n\r\n");
        try w.interface.flush();

        var r_buf: [1024]u8 = undefined;
        var r = stream.reader(io, &r_buf);
        try r.interface.fill(1);
        const n = r.interface.buffered().len;
        try testing.expect(std.mem.indexOf(u8, r_buf[0..n], "200 OK") != null);
        try testing.expect(std.mem.indexOf(u8, r_buf[0..n], "OK") != null);
    }

    {
        // Test /fraud-score
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        const payload =
            \\{
            \\  "transaction": {"amount": 100, "installments": 1, "requested_at": "2026-03-11T18:45:53Z"},
            \\  "customer": {"avg_amount": 100, "tx_count_24h": 1, "known_merchants": []},
            \\  "merchant": {"id": "M-1", "mcc": "5411", "avg_amount": 50},
            \\  "terminal": {"is_online": true, "card_present": true, "km_from_home": 0},
            \\  "last_transaction": null
            \\}
        ;

        var req_buf: [2048]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "POST /fraud-score HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });

        var w_buf: [2048]u8 = undefined;
        var w = stream.writer(io, &w_buf);
        try w.interface.writeAll(req);
        try w.interface.flush();

        var res_buf: [1024]u8 = undefined;
        var r = stream.reader(io, &res_buf);
        try r.interface.fill(1);
        const n = r.interface.buffered().len;
        try testing.expect(std.mem.indexOf(u8, res_buf[0..n], "200 OK") != null);
        try testing.expect(std.mem.indexOf(u8, res_buf[0..n], "fraud_score") != null);
    }

    {
        // Test 404
        const stream = try addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var w_buf: [256]u8 = undefined;
        var w = stream.writer(io, &w_buf);
        try w.interface.writeAll("GET /not-exists HTTP/1.1\r\n\r\n");
        try w.interface.flush();

        var r_buf: [1024]u8 = undefined;
        var r = stream.reader(io, &r_buf);
        try r.interface.fill(1);
        const n = r.interface.buffered().len;
        try testing.expect(std.mem.indexOf(u8, r_buf[0..n], "404 Not Found") != null);
    }

    // 4. Cleanup
    _ = server_thread;
}
