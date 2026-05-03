//! Shared HTTP types: application context, request representation, and method enum.
//! Separated from the server to avoid coupling wiring logic with transport parsing.

const std = @import("std");
const engine = @import("engine");
const core = @import("core");

/// Shared application state, initialized once at startup and read concurrently
/// by all connection handlers. All fields are immutable after construction.
pub const AppContext = struct {
    /// SoA-layout reference dataset, memory-mapped from `data/references.bin`.
    dataset: engine.SoADataset,
    /// IVF index with cluster centroids, loaded from `resources/index.bin`.
    index: engine.IvfIndex,
    /// Fraud/legit labels (one byte per reference), from `data/labels.bin`.
    labels: [*]const u8,
    /// Feature normalization bounds from `resources/normalization.json`.
    norm_constants: core.norm.NormalizationConstants,
    /// MCC code → risk score mapping from `resources/mcc_risk.json`.
    mcc_risk: std.StringHashMap(f64),
};

/// HTTP method enum.
pub const Method = enum { GET, POST, UNKNOWN };

/// Parsed HTTP request passed to route handlers.
pub const Request = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
};
