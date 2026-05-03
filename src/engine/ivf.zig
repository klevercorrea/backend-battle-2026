//! Inverted File (IVF) index for approximate nearest-neighbor search.
//! Uses SIMD-accelerated distance computation over SoA-layout datasets.

const std = @import("std");

/// Number of feature dimensions per vector.
pub const vector_dim = 16;

/// Number of IVF clusters (partitions).
pub const k_clusters = 6;

/// Number of nearest neighbors returned by search.
pub const k_nearest = 5;

// ── Safe public API ────────────────────────────────────────────────

/// Represents a dataset in Structure of Arrays (SoA) format.
/// Each dimension is stored as a contiguous, 64-byte aligned array
/// to enable cache-line-width SIMD loads.
pub const SoADataset = struct {
    /// Dimension arrays, each aligned to 64 bytes for SIMD/cache-line efficiency.
    dims: [vector_dim][*]align(64) const f32,
    /// Actual number of references.
    n: usize,
    /// Padded number of references (multiple of 16).
    n_padded: usize,

    /// Initializes a SoADataset from a raw memory-mapped buffer of f32s.
    /// The buffer must contain (n_padded * vector_dim) floats.
    pub fn init(data: []const f32, n: usize) SoADataset {
        const n_padded = (n + 15) & ~@as(usize, 15);
        std.debug.assert(data.len >= n_padded * vector_dim);

        var self: SoADataset = undefined;
        self.n = n;
        self.n_padded = n_padded;

        for (0..vector_dim) |i| {
            const offset = i * n_padded;
            const ptr = data.ptr + offset;
            if (@intFromPtr(ptr) % 64 != 0) {
                @panic("SoA dimension pointer not 64-byte aligned");
            }
            // Each dimension array starts at a 64-byte boundary because n_padded is multiple of 16.
            self.dims[i] = @ptrCast(@alignCast(ptr));
        }
        return self;
    }
};

/// Represents the IVF index metadata: cluster centroids, offsets, and lengths.
pub const IvfIndex = struct {
    centroids: [k_clusters][vector_dim]f32,
    offsets: [k_clusters]u32,
    lengths: [k_clusters]u32,
};

/// Result of a nearest neighbor search.
pub const KnnResult = struct {
    /// 0-based indices into the dataset. Unmatched slots contain -1.
    indices: [k_nearest]c_int,
    /// Squared Euclidean distances, sorted ascending.
    /// Unmatched slots contain a large sentinel value (~1e30).
    distances: [k_nearest]f32,
};

/// Performs a k-nearest neighbor search using the IVF index to skip unrelated clusters.
pub fn searchIvf(query: *const [vector_dim]f32, dataset: SoADataset, index: IvfIndex) KnnResult {
    // 1. Find the nearest centroid
    var min_dist: f32 = std.math.inf(f32);
    var best_k: usize = 0;

    const q_vec: @Vector(vector_dim, f32) = query.*;
    for (0..k_clusters) |ki| {
        const c_vec: @Vector(vector_dim, f32) = index.centroids[ki];
        const diff = q_vec - c_vec;
        const dist = @reduce(.Add, diff * diff);

        if (dist < min_dist) {
            min_dist = dist;
            best_k = ki;
        }
    }

    // 2. Perform KNN search only within the chosen cluster
    const cluster_offset = index.offsets[best_k];
    const cluster_len = index.lengths[best_k];
    const cluster_padded_len = (cluster_len + 15) & ~@as(u32, 15);

    var result: KnnResult = .{
        .indices = [_]c_int{-1} ** k_nearest,
        .distances = [_]f32{1e30} ** k_nearest,
    };

    const lane_count = 16;
    var i: usize = cluster_offset;
    const end = cluster_offset + cluster_padded_len;

    while (i < end) : (i += lane_count) {
        var dist_vec: @Vector(lane_count, f32) = @splat(0.0);

        inline for (0..vector_dim) |dim| {
            const q: @Vector(lane_count, f32) = @splat(query[dim]);
            const r: @Vector(lane_count, f32) = dataset.dims[dim][i..][0..lane_count].*;
            const diff = q - r;
            dist_vec += diff * diff;

            if (dim % 4 == 3) {
                if (@reduce(.Min, dist_vec) > result.distances[k_nearest - 1]) break;
            }
        }

        // Branchless update of top-k
        inline for (0..lane_count) |lane| {
            const d = dist_vec[lane];
            if (d < result.distances[k_nearest - 1]) {
                insertSorted(&result, @intCast(i + lane), d);
            }
        }
    }

    return result;
}

fn insertSorted(result: *KnnResult, index: c_int, distance: f32) void {
    var pos: usize = k_nearest - 1;
    while (pos > 0 and distance < result.distances[pos - 1]) : (pos -= 1) {
        result.indices[pos] = result.indices[pos - 1];
        result.distances[pos] = result.distances[pos - 1];
    }
    result.indices[pos] = index;
    result.distances[pos] = distance;
}

// ── Tests ──────────────────────────────────────────────────────────

test "SoADataset.init aligns pointers correctly" {
    const testing = std.testing;
    const n = 10;
    const n_padded = 16;

    const buffer = try testing.allocator.alignedAlloc(f32, .@"64", n_padded * vector_dim);
    defer testing.allocator.free(buffer);
    @memset(buffer, 0);

    const ds = SoADataset.init(buffer, n);

    try testing.expectEqual(@as(usize, 10), ds.n);
    try testing.expectEqual(@as(usize, 16), ds.n_padded);

    for (0..vector_dim) |i| {
        const ptr_val = @intFromPtr(ds.dims[i]);
        try testing.expect(ptr_val % 64 == 0);
        try testing.expectEqual(ds.dims[i], buffer.ptr + (i * n_padded));
    }
}
