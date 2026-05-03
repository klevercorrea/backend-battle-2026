//! Pre-assembled HTTP response byte strings.
//! Generated at comptime to guarantee Content-Length correctness
//! and eliminate runtime formatting overhead in the hot path.

const std = @import("std");

fn buildScoreResponse(comptime approved: bool, comptime score: []const u8) []const u8 {
    const approved_str = if (approved) "true" else "false";
    const body = "{\"approved\":" ++ approved_str ++ ",\"fraud_score\":" ++ score ++ "}";
    return std.fmt.comptimePrint(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
}

/// Pre-computed HTTP responses indexed by fraud count (0–5).
pub const scores = [_][]const u8{
    buildScoreResponse(true, "0.0"),
    buildScoreResponse(true, "0.2"),
    buildScoreResponse(true, "0.4"),
    buildScoreResponse(false, "0.6"),
    buildScoreResponse(false, "0.8"),
    buildScoreResponse(false, "1.0"),
};

pub const ok_ready = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nOK";
pub const err_400 = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n\r\nInvalid JSON";
pub const err_404 = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nNot Found";
pub const err_413 = "HTTP/1.1 413 Payload Too Large\r\nContent-Type: text/plain\r\nContent-Length: 17\r\n\r\nPayload Too Large";
pub const err_500 = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 21\r\n\r\nInternal Server Error";
