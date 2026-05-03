//! Vector search engine module.
//! Re-exports the IVF index, SIMD search, and fraud scoring pipeline.

pub const ivf = @import("ivf.zig");
pub const scoring = @import("scoring.zig");

// Re-export commonly used types and functions at the top level.
pub const SoADataset = ivf.SoADataset;
pub const IvfIndex = ivf.IvfIndex;
pub const KnnResult = ivf.KnnResult;
pub const searchIvf = ivf.searchIvf;
pub const vector_dim = ivf.vector_dim;
pub const k_clusters = ivf.k_clusters;
pub const k_nearest = ivf.k_nearest;

test {
    _ = ivf;
    _ = scoring;
}
