//! HTTP request handlers. Each handler is a pure function of
//! (Io, Stream, AppContext, Request) → error!void.
//! Handlers orchestrate domain logic but contain no HTTP parsing.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const core = @import("core");
const engine = @import("engine");

const resp = @import("responses.zig");
const ctx_mod = @import("context.zig");

const AppContext = ctx_mod.AppContext;
const Request = ctx_mod.Request;

/// Health check endpoint — returns 200 OK immediately.
pub fn handleReady(io: Io, stream: net.Stream, _: *const AppContext, _: Request) !void {
    var w_buf: [256]u8 = undefined;
    var w = stream.writer(io, &w_buf);
    try w.interface.writeAll(resp.ok_ready);
    try w.interface.flush();
}

/// Fraud scoring endpoint — parses the transaction JSON, delegates to the
/// scoring pipeline in `engine.scoring`, and returns the result as JSON.
pub fn handleFraudScore(io: Io, stream: net.Stream, ctx: *const AppContext, req: Request) !void {
    var scanner = core.json.JsonScanner.init(req.body);
    const payload = scanner.scan() catch {
        var w_buf: [256]u8 = undefined;
        var w = stream.writer(io, &w_buf);
        try w.interface.writeAll(resp.err_400);
        try w.interface.flush();
        return;
    };

    const frauds = engine.scoring.scoreFraud(
        &payload,
        ctx.dataset,
        ctx.index,
        ctx.labels,
        &ctx.norm_constants,
        &ctx.mcc_risk,
    );

    var w_buf: [512]u8 = undefined;
    var w = stream.writer(io, &w_buf);
    try w.interface.writeAll(resp.scores[frauds]);
    try w.interface.flush();
}
