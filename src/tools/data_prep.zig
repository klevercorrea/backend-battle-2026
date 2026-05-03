//! Offline data preparation pipeline: parses reference JSON,
//! clusters with K-Means, and writes SoA binary + IVF index files.

const std = @import("std");
const testing = std.testing;
const core = @import("core");
const engine = @import("engine");

/// Represents a labeled transaction vector from the reference dataset.
pub const Reference = struct {
    vector: [14]f32,
    label: []const u8,
};

pub const NormalizationConstants = core.norm.NormalizationConstants;

/// Parses a JSON array of Reference objects.
pub fn parseReferences(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed([]Reference) {
    return std.json.parseFromSlice([]Reference, allocator, json_text, .{ .ignore_unknown_fields = true });
}

/// Parses a JSON object containing normalization constants.
pub fn parseNormalization(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(NormalizationConstants) {
    return std.json.parseFromSlice(NormalizationConstants, allocator, json_text, .{ .ignore_unknown_fields = true });
}

/// Parses the MCC risk JSON into a generic JSON value.
pub fn parseMccRisk(allocator: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
}

/// Decompresses gzip data and returns the decompressed content.
/// Caller owns the returned memory.
pub fn decompressGzip(allocator: std.mem.Allocator, compressed_data: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(compressed_data);
    const window_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window_buffer);

    var decompressor = std.compress.flate.Decompress.init(&reader, .gzip, window_buffer);
    return try decompressor.reader.allocRemaining(allocator, .unlimited);
}

/// Transforms a 14D vector into a 16D vector by adding two zero dimensions.
pub fn transformTo16D(vector14: [14]f32) [16]f32 {
    var vector16: [16]f32 = undefined;
    @memcpy(vector16[0..14], &vector14);
    vector16[14] = 0;
    vector16[15] = 0;
    return vector16;
}

/// Represents the IVF index metadata.
/// Re-exported from the engine module to avoid struct duplication.
pub const IvfIndex = engine.IvfIndex;

/// Assigns each reference to one of K clusters using K-Means.
/// Returns the centroids and an array of cluster indices (one per reference).
pub fn clusterReferences(allocator: std.mem.Allocator, references: []const Reference, k: usize, max_iterations: usize) !struct { centroids: [][16]f32, assignments: []u32 } {
    const n = references.len;
    var centroids = try allocator.alloc([16]f32, k);
    errdefer allocator.free(centroids);
    var assignments = try allocator.alloc(u32, n);
    errdefer allocator.free(assignments);

    // 1. Initialize centroids randomly from the dataset
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..k) |i| {
        const idx = random.intRangeLessThan(usize, 0, n);
        centroids[i] = transformTo16D(references[idx].vector);
    }

    // 2. Iterative optimization
    for (0..max_iterations) |_| {
        var changed = false;

        // Assignment step
        for (0..n) |i| {
            const v = transformTo16D(references[i].vector);
            var min_dist: f32 = std.math.inf(f32);
            var best_k: u32 = 0;

            for (0..k) |ki| {
                var dist: f32 = 0;
                for (0..16) |d| {
                    const diff = v[d] - centroids[ki][d];
                    dist += diff * diff;
                }
                if (dist < min_dist) {
                    min_dist = dist;
                    best_k = @intCast(ki);
                }
            }

            if (assignments[i] != best_k) {
                assignments[i] = best_k;
                changed = true;
            }
        }

        if (!changed) break;

        // Update step
        var new_centroids = try allocator.alloc([16]f32, k);
        defer allocator.free(new_centroids);
        @memset(new_centroids, @as([16]f32, @splat(0.0)));
        var counts = try allocator.alloc(f32, k);
        defer allocator.free(counts);
        @memset(counts, 0.0);

        for (0..n) |i| {
            const ki = assignments[i];
            const v = transformTo16D(references[i].vector);
            for (0..16) |d| {
                new_centroids[ki][d] += v[d];
            }
            counts[ki] += 1.0;
        }

        for (0..k) |ki| {
            if (counts[ki] > 0) {
                for (0..16) |d| {
                    centroids[ki][d] = new_centroids[ki][d] / counts[ki];
                }
            }
        }
    }

    return .{ .centroids = centroids, .assignments = assignments };
}

/// Represents a reference with its assigned cluster.
const ClusteredReference = struct {
    ref: Reference,
    cluster_id: u32,
};

fn compareClusteredReferences(context: void, a: ClusteredReference, b: ClusteredReference) bool {
    _ = context;
    return a.cluster_id < b.cluster_id;
}

/// Writes clustered references to binary files and generates the IVF index.
pub fn writeClusteredReferences(allocator: std.mem.Allocator, references: []const Reference, centroids: [][16]f32, assignments: []u32, data_path: []const u8, labels_path: []const u8, index_path: []const u8) !void {
    const io = std.Options.debug_io;
    var dir = std.Io.Dir.cwd();

    // 1. Group and Sort references by cluster
    var clustered = try allocator.alloc(ClusteredReference, references.len);
    defer allocator.free(clustered);
    for (0..references.len) |i| {
        clustered[i] = .{ .ref = references[i], .cluster_id = assignments[i] };
    }
    std.mem.sort(ClusteredReference, clustered, {}, compareClusteredReferences);

    // 2. Calculate offsets and lengths for each cluster
    var index = IvfIndex{
        .centroids = undefined,
        .offsets = undefined,
        .lengths = undefined,
    };
    for (0..6) |i| {
        index.centroids[i] = centroids[i];
        index.offsets[i] = 0;
        index.lengths[i] = 0;
    }

    var current_cluster: u32 = 0;
    var current_offset: u32 = 0;
    for (clustered) |c| {
        while (c.cluster_id > current_cluster) {
            // Align the START of the next cluster to 16-vector boundary
            current_offset = (current_offset + 15) & ~@as(u32, 15);
            current_cluster += 1;
            index.offsets[current_cluster] = current_offset;
        }
        index.lengths[current_cluster] += 1;
        current_offset += 1;
    }

    // 3. Write segmented SoA binary (references)
    var data_file = try dir.createFile(io, data_path, .{});
    defer data_file.close(io);
    var data_buf: [4096]u8 = undefined;
    var data_writer = data_file.writer(io, &data_buf);

    const total_vectors_padded = (current_offset + 15) & ~@as(u32, 15);

    for (0..16) |dim| {
        var written_in_dim: u32 = 0;
        for (0..6) |ki| {
            const cluster_start = index.offsets[ki];
            const cluster_len = index.lengths[ki];
            const cluster_padded_len = if (ki < 5) index.offsets[ki + 1] - cluster_start else (total_vectors_padded - cluster_start);

            // Find the slice of clustered references for this group
            var refs_in_cluster: []const ClusteredReference = &.{};
            var start_idx: usize = 0;
            for (clustered, 0..) |c, idx| {
                if (c.cluster_id == ki) {
                    start_idx = idx;
                    break;
                }
            }
            refs_in_cluster = clustered[start_idx .. start_idx + cluster_len];

            for (0..cluster_padded_len) |i| {
                const val: f32 = if (i < cluster_len and dim < 14) refs_in_cluster[i].ref.vector[dim] else 0.0;
                try data_writer.interface.writeAll(std.mem.asBytes(&val));
                written_in_dim += 1;
            }
        }
        // Final padding for the entire SoA array
        while (written_in_dim < total_vectors_padded) {
            const zero: f32 = 0.0;
            try data_writer.interface.writeAll(std.mem.asBytes(&zero));
            written_in_dim += 1;
        }
    }
    try data_writer.flush();

    // 4. Write segmented binary (labels)
    var labels_file = try dir.createFile(io, labels_path, .{});
    defer labels_file.close(io);
    var labels_buf: [4096]u8 = undefined;
    var labels_writer = labels_file.writer(io, &labels_buf);

    var written_labels: u32 = 0;
    for (0..6) |ki| {
        const cluster_start = index.offsets[ki];
        const cluster_len = index.lengths[ki];
        const cluster_padded_len = if (ki < 5) index.offsets[ki + 1] - cluster_start else (total_vectors_padded - cluster_start);

        var start_idx: usize = 0;
        for (clustered, 0..) |c, idx| {
            if (c.cluster_id == ki) {
                start_idx = idx;
                break;
            }
        }

        for (0..cluster_padded_len) |i| {
            const label: u8 = if (i < cluster_len and std.mem.eql(u8, clustered[start_idx + i].ref.label, "fraud")) 1 else 0;
            try labels_writer.interface.writeByte(label);
            written_labels += 1;
        }
    }
    while (written_labels < total_vectors_padded) {
        try labels_writer.interface.writeByte(0);
        written_labels += 1;
    }
    try labels_writer.flush();

    // 5. Write Index File
    var index_file = try dir.createFile(io, index_path, .{});
    defer index_file.close(io);
    try index_file.writeStreamingAll(io, std.mem.asBytes(&index));
}

test "parse single reference object" {
    const json =
        \\ [
        \\  {
        \\    "vector": [0.01, 0.0833, 0.05, 0.8261, 0.1667, -1, -1, 0.0432, 0.25, 0, 1, 0, 0.2, 0.0416],
        \\    "label": "legit"
        \\  }
        \\ ]
    ;

    var parsed = try parseReferences(testing.allocator, json);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.len);
    try testing.expectEqual(@as(f32, 0.01), parsed.value[0].vector[0]);
    try testing.expectEqualStrings("legit", parsed.value[0].label);
}

test "parse normalization" {
    const json =
        \\ {
        \\   "max_amount": 10000,
        \\   "max_installments": 12,
        \\   "amount_vs_avg_ratio": 10,
        \\   "max_minutes": 1440,
        \\   "max_km": 1000,
        \\   "max_tx_count_24h": 20,
        \\   "max_merchant_avg_amount": 10000
        \\ }
    ;

    var parsed = try parseNormalization(testing.allocator, json);
    defer parsed.deinit();

    try testing.expectEqual(@as(f64, 10000), parsed.value.max_amount);
    try testing.expectEqual(@as(f64, 12), parsed.value.max_installments);
}

test "decompress gzip" {
    // "hello world" compressed with gzip
    const compressed = [_]u8{
        0x1f, 0x8b, 0x08, 0x08, 0x3d, 0x47, 0x6e, 0x66, 0x00, 0x03, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e,
        0x74, 0x78, 0x74, 0x00, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01,
        0x00, 0x85, 0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
    };

    const decompressed = try decompressGzip(testing.allocator, &compressed);
    defer testing.allocator.free(decompressed);

    try testing.expectEqualStrings("hello world", decompressed);
}

test "transform 14D to 16D" {
    const v14 = [14]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    const v16 = transformTo16D(v14);

    try testing.expectEqual(@as(f32, 1), v16[0]);
    try testing.expectEqual(@as(f32, 14), v16[13]);
    try testing.expectEqual(@as(f32, 0), v16[14]);
    try testing.expectEqual(@as(f32, 0), v16[15]);
}
