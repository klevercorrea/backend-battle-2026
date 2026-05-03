//! Core domain module. Re-exports JSON parsing and feature normalization.

pub const json = @import("json.zig");
pub const norm = @import("norm.zig");

test {
    _ = json;
    _ = norm;
}
