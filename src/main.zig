//! Entry point for the Rinha de Backend 2026 fraud-detection server.
//! Loads pre-computed IVF index and reference dataset via mmap, then starts
//! an HTTP server on a Unix domain socket or TCP port 9999.

const std = @import("std");
const engine = @import("engine");
const core = @import("core");
const server = @import("http");

pub fn main(init: std.process.Init) !void {
    // Resilience: Ignore SIGPIPE to prevent process termination when writing to closed sockets.
    std.posix.sigaction(std.posix.SIG.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    const allocator = init.gpa;
    const io = init.io;

    const file = try std.Io.Dir.cwd().openFile(io, "data/references.bin", .{});
    defer file.close(io);
    const stat = try file.stat(io);

    const mmap_ptr = try std.posix.mmap(
        null,
        stat.size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        file.handle,
        0,
    );
    defer std.posix.munmap(mmap_ptr);

    const lfile = try std.Io.Dir.cwd().openFile(io, "data/labels.bin", .{});
    defer lfile.close(io);
    const lstat = try lfile.stat(io);
    const lmmap_ptr = try std.posix.mmap(
        null,
        lstat.size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        lfile.handle,
        0,
    );
    defer std.posix.munmap(lmmap_ptr);

    const norm_json = try std.Io.Dir.cwd().readFileAlloc(io, "resources/normalization.json", allocator, .unlimited);
    defer allocator.free(norm_json);
    const parsed_norm = try std.json.parseFromSlice(core.norm.NormalizationConstants, allocator, norm_json, .{ .ignore_unknown_fields = true });
    defer parsed_norm.deinit();

    const mcc_json = try std.Io.Dir.cwd().readFileAlloc(io, "resources/mcc_risk.json", allocator, .unlimited);
    defer allocator.free(mcc_json);
    const parsed_mcc = try std.json.parseFromSlice(std.json.Value, allocator, mcc_json, .{});
    defer parsed_mcc.deinit();

    var mcc_risk = std.StringHashMap(f64).init(allocator);
    defer mcc_risk.deinit();
    var it = parsed_mcc.value.object.iterator();
    while (it.next()) |entry| {
        try mcc_risk.put(entry.key_ptr.*, entry.value_ptr.float);
    }

    // Load IVF Index
    var index_buf: [@sizeOf(engine.IvfIndex)]u8 align(@alignOf(engine.IvfIndex)) = undefined;
    const index_file = try std.Io.Dir.cwd().openFile(io, "resources/index.bin", .{});
    defer index_file.close(io);
    _ = try index_file.readPositionalAll(io, &index_buf, 0);
    const index: *const engine.IvfIndex = @ptrCast(@alignCast(&index_buf));

    const n_padded = stat.size / (engine.vector_dim * @sizeOf(f32));

    const app: server.AppContext = .{
        .dataset = engine.SoADataset.init(@ptrCast(@alignCast(mmap_ptr[0..stat.size])), n_padded),
        .index = index.*,
        .labels = @ptrCast(@alignCast(lmmap_ptr)),
        .norm_constants = parsed_norm.value,
        .mcc_risk = mcc_risk,
    };

    const socket_path = init.environ_map.get("SOCKET_PATH");
    try server.run(io, &app, socket_path);
}
