//! Feature normalization for the fraud-detection model.
//! Transforms a `TransactionPayload` into a 14-dimensional f32 vector
//! with all values clamped to [0, 1].

const std = @import("std");
const json = @import("json.zig");
const TransactionPayload = json.TransactionPayload;

/// Upper bounds used to normalize each raw feature into the [0, 1] range.
/// Loaded from `resources/normalization.json` at startup.
pub const NormalizationConstants = struct {
    max_amount: f64,
    max_installments: f64,
    amount_vs_avg_ratio: f64,
    max_minutes: f64,
    max_km: f64,
    max_tx_count_24h: f64,
    max_merchant_avg_amount: f64,
};

/// The 14 normalized feature dimensions, in column order.
/// Backed by u4 — adding a 15th without expanding the backing type
/// will produce a comptime error.
pub const Feature = enum(u4) {
    amount,
    installments,
    amount_vs_avg,
    hour_of_day,
    day_of_week,
    minutes_since_last_tx,
    km_from_last_tx,
    km_from_home,
    tx_count_24h,
    is_online,
    card_present,
    unknown_merchant,
    mcc_risk,
    merchant_avg_amount,

    pub const count = @typeInfo(Feature).@"enum".fields.len;

    pub fn i(self: Feature) usize {
        return @intFromEnum(self);
    }
};

/// Converts a parsed transaction payload into a normalized feature vector.
/// Returns an array of `Feature.count` f32 values, each clamped to [0, 1].
pub fn normalize(
    payload: *const TransactionPayload,
    constants: *const NormalizationConstants,
) [Feature.count]f32 {
    var v: [Feature.count]f32 = undefined;

    const amount_f64 = payload.transaction.amount;
    v[Feature.amount.i()] = round4(clamp(@as(f32, @floatCast(amount_f64 / constants.max_amount))));
    v[Feature.installments.i()] = round4(clamp(@as(f32, @floatCast(@as(f64, @floatFromInt(payload.transaction.installments)) / constants.max_installments))));
    v[Feature.amount_vs_avg.i()] = round4(clamp(@as(f32, @floatCast((amount_f64 / payload.customer.avg_amount) / constants.amount_vs_avg_ratio))));

    const hour = parseHour(payload.transaction.requested_at);
    v[Feature.hour_of_day.i()] = round4(@as(f32, @floatCast(@as(f64, @floatFromInt(hour)) / 23.0)));

    const dow = parseDayOfWeek(payload.transaction.requested_at);
    v[Feature.day_of_week.i()] = round4(@as(f32, @floatCast(@as(f64, @floatFromInt(dow)) / 6.0)));

    if (payload.last_transaction) |last| {
        const diff_seconds = diffTimestamps(payload.transaction.requested_at, last.timestamp);
        const mins = @as(f64, @floatFromInt(diff_seconds)) / 60.0;
        v[Feature.minutes_since_last_tx.i()] = round4(clamp(@as(f32, @floatCast(mins / constants.max_minutes))));
        v[Feature.km_from_last_tx.i()] = round4(clamp(@as(f32, @floatCast(last.km_from_current / constants.max_km))));
    } else {
        // Official generator uses -1.0 as sentinel for missing last_transaction.
        v[Feature.minutes_since_last_tx.i()] = -1.0;
        v[Feature.km_from_last_tx.i()] = -1.0;
    }

    v[Feature.km_from_home.i()] = round4(clamp(@as(f32, @floatCast(payload.terminal.km_from_home / constants.max_km))));
    v[Feature.tx_count_24h.i()] = round4(clamp(@as(f32, @floatCast(@as(f64, @floatFromInt(payload.customer.tx_count_24h)) / constants.max_tx_count_24h))));
    v[Feature.is_online.i()] = if (payload.terminal.is_online) 1.0 else 0.0;
    v[Feature.card_present.i()] = if (payload.terminal.card_present) 1.0 else 0.0;

    v[Feature.unknown_merchant.i()] = if (payload.customer.is_merchant_known) 0.0 else 1.0;

    // Fast MCC risk lookup based on static competition data.
    const risk: f32 = switch (std.fmt.parseInt(u16, payload.merchant.mcc, 10) catch 0) {
        4511 => 0.35,
        5311 => 0.25,
        5411 => 0.15,
        5812 => 0.30,
        5912 => 0.20,
        5944 => 0.45,
        5999 => 0.50,
        7801 => 0.80,
        7802 => 0.75,
        7995 => 0.85,
        else => 0.5,
    };
    v[Feature.mcc_risk.i()] = round4(risk);
    v[Feature.merchant_avg_amount.i()] = round4(clamp(@as(f32, @floatCast(payload.merchant.avg_amount / constants.max_merchant_avg_amount))));

    return v;
}

/// Round to 4 decimal places, matching the official C generator's `round4`.
fn round4(v: f32) f32 {
    return @round(v * 10000.0) / 10000.0;
}

/// Clamp to [0, 1]. Lowers to MINSS + MAXSS — branchless.
fn clamp(x: f32) f32 {
    return @max(0.0, @min(1.0, x));
}

fn parseHour(ts: []const u8) u8 {
    // 2026-03-11T18:45:53Z
    // Hour is at index 11-13
    if (ts.len < 13) return 0;
    return std.fmt.parseInt(u8, ts[11..13], 10) catch 0;
}

fn parseDayOfWeek(ts: []const u8) u8 {
    // 2026-03-11T18:45:53Z
    if (ts.len < 10) return 0;
    const year = std.fmt.parseInt(i32, ts[0..4], 10) catch 2026;
    const month = std.fmt.parseInt(i32, ts[5..7], 10) catch 3;
    const day = std.fmt.parseInt(i32, ts[8..10], 10) catch 11;

    // Sakamoto's algorithm
    const t_arr = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y = year;
    if (month < 3) y -= 1;
    const dow = @mod(y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + t_arr[@as(usize, @intCast(month - 1))] + day, 7);
    // dow: 0=Sun, 1=Mon, ..., 6=Sat
    // Rinha: seg=0, dom=6
    // Map Sun(0)->6, Mon(1)->0, ..., Sat(6)->5
    return @as(u8, @intCast(if (dow == 0) 6 else dow - 1));
}

fn diffTimestamps(ts1: []const u8, ts2: []const u8) i64 {
    const s1 = parseToSeconds(ts1);
    const s2 = parseToSeconds(ts2);
    return @as(i64, @intCast(s1)) - @as(i64, @intCast(s2));
}

fn parseToSeconds(ts: []const u8) u64 {
    if (ts.len < 19) return 0;
    const year = std.fmt.parseInt(u64, ts[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(u64, ts[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(u64, ts[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(u64, ts[11..13], 10) catch return 0;
    const min = std.fmt.parseInt(u64, ts[14..16], 10) catch return 0;
    const sec = std.fmt.parseInt(u64, ts[17..19], 10) catch return 0;

    // Cumulative days per month (non-leap). Leap year error ≤ 24h,
    // acceptable for a feature capped at max_minutes (1440).
    const cumulative = [_]u64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    if (month == 0 or month > 12) return 0;
    const total_days = year * 365 + cumulative[month - 1] + day;
    return total_days * 86400 + hour * 3600 + min * 60 + sec;
}
