//! HTTP transport module.
//! Provides the async server, comptime router, request handlers,
//! and pre-built responses.

pub const context = @import("context.zig");
pub const handlers = @import("handlers.zig");
pub const server = @import("server.zig");
pub const responses = @import("responses.zig");

// Re-export commonly used types and functions for convenience.
pub const AppContext = context.AppContext;
pub const run = server.run;

test {
    _ = context;
    _ = handlers;
    _ = server;
    _ = responses;
}
