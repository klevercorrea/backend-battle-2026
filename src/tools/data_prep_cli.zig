//! CLI entry point for the offline data preparation pipeline.
//! Reads reference JSON, clusters with K-Means, and writes SoA binary + IVF index files.

const std = @import("std");
const data_prep = @import("data_prep.zig");
const engine = @import("engine");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const references_json = try std.Io.Dir.cwd().readFileAlloc(io, "resources/references.json", allocator, .unlimited);
    defer allocator.free(references_json);

    var parsed = try data_prep.parseReferences(allocator, references_json);
    defer parsed.deinit();

    std.debug.print("Clustering {d} references into {d} groups...\n", .{ parsed.value.len, engine.k_clusters });
    const cluster_results = try data_prep.clusterReferences(allocator, parsed.value, engine.k_clusters, 50);
    defer allocator.free(cluster_results.centroids);
    defer allocator.free(cluster_results.assignments);

    try data_prep.writeClusteredReferences(
        allocator,
        parsed.value,
        cluster_results.centroids,
        cluster_results.assignments,
        "data/references.bin",
        "data/labels.bin",
        "data/index.bin",
    );

    std.debug.print("Successfully wrote clustered references and IVF index.\n", .{});
}
