//! Fraud scoring pipeline: normalize → search → classify.
//! Pure business logic with no HTTP or I/O awareness.

const std = @import("std");
const core = @import("core");
const ivf = @import("ivf.zig");

/// Scores a transaction for fraud using KNN classification.
/// Orchestrates the full pipeline: feature normalization, SIMD vector
/// search, and label counting. Returns the number of fraudulent
/// neighbors found (0–`ivf.k_nearest`).
pub fn scoreFraud(
    payload: *const core.json.TransactionPayload,
    dataset: ivf.SoADataset,
    index: ivf.IvfIndex,
    labels: [*]const u8,
    norm_constants: *const core.norm.NormalizationConstants,
) usize {
    // 1. Normalize payload → 14D feature vector
    const vector14 = core.norm.normalize(payload, norm_constants);

    // 2. Pad to 16D for SIMD alignment
    var query: [ivf.vector_dim]f32 = [_]f32{0} ** ivf.vector_dim;
    @memcpy(query[0..core.norm.Feature.count], &vector14);

    // 3. KNN search
    const result = ivf.searchIvf(&query, dataset, index);

    // 4. Count fraud labels among neighbors
    var frauds: usize = 0;
    for (result.indices) |idx| {
        if (idx >= 0 and labels[@as(usize, @intCast(idx))] == 1) {
            frauds += 1;
        }
    }
    return frauds;
}
