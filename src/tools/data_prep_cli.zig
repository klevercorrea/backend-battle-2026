//! CLI entry point for the offline data preparation pipeline.
//! Reads reference JSON, clusters with K-Means, and writes SoA binary + IVF index files.

const std = @import("std");
const data_prep = @import("data_prep.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const references_json = try std.Io.Dir.cwd().readFileAlloc(io, "resources/example-references.json", allocator, .unlimited);
    defer allocator.free(references_json);

    var parsed = try data_prep.parseReferences(allocator, references_json);
    defer parsed.deinit();

    std.debug.print("Clustering {d} references into 6 groups...\n", .{parsed.value.len});
    const cluster_results = try data_prep.clusterReferences(allocator, parsed.value, 6, 50);
    defer allocator.free(cluster_results.centroids);
    defer allocator.free(cluster_results.assignments);

    try data_prep.writeClusteredReferences(
        allocator,
        parsed.value,
        cluster_results.centroids,
        cluster_results.assignments,
        "data/references.bin",
        "data/labels.bin",
        "resources/index.bin",
    );

    std.debug.print("Successfully wrote clustered references and IVF index.\n", .{});
}
