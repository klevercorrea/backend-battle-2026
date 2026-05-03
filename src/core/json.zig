//! Zero-allocation JSON scanner optimized for the Rinha transaction payload.
//! Uses key-search jumping instead of building a parse tree.

const std = @import("std");

/// Simple zero-allocation JSON scanner for the rinha payload.
/// It uses memchr to jump between keys and values.
pub const JsonScanner = struct {
    buffer: []const u8,
    pos: usize,

    pub fn init(buffer: []const u8) JsonScanner {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn scan(self: *JsonScanner) !TransactionPayload {
        var payload: TransactionPayload = .{
            .transaction = undefined,
            .customer = undefined,
            .merchant = undefined,
            .terminal = undefined,
            .last_transaction = null,
        };

        self.pos = 0;

        // Transaction sub-object
        payload.transaction.amount = try self.findFloat("amount", null);
        payload.transaction.installments = @intCast(try self.findInt("installments"));
        payload.transaction.requested_at = try self.findString("requested_at", null);

        // Customer sub-object
        payload.customer.avg_amount = try self.findFloat("avg_amount", null);
        payload.customer.tx_count_24h = @intCast(try self.findInt("tx_count_24h"));

        // Merchant sub-object - get merchant_id first
        const merchant_id = try self.findString("id", "merchant");
        payload.merchant.mcc = try self.findString("mcc", "merchant");
        payload.merchant.avg_amount = try self.findFloat("avg_amount", "merchant");
        payload.merchant.id = merchant_id;

        // Now we can check known_merchants zero-allocation
        payload.customer.is_merchant_known = try self.checkMerchantKnown(merchant_id);

        // Terminal sub-object
        payload.terminal.is_online = try self.findBool("is_online");
        payload.terminal.card_present = try self.findBool("card_present");
        payload.terminal.km_from_home = try self.findFloat("km_from_home", null);

        // Optional last_transaction
        if (self.findKey("last_transaction", 0)) |key_pos| {
            self.pos = key_pos + 16 + 1;
            self.skipWhitespace();
            if (self.pos < self.buffer.len and self.buffer[self.pos] == ':') {
                self.pos += 1;
                self.skipWhitespace();
                if (self.pos + 4 <= self.buffer.len and !std.mem.startsWith(u8, self.buffer[self.pos..], "null")) {
                    payload.last_transaction = .{
                        .timestamp = try self.findString("timestamp", "last_transaction"),
                        .km_from_current = try self.findFloat("km_from_current", "last_transaction"),
                    };
                }
            }
        }

        return payload;
    }

    fn findKey(self: *JsonScanner, key: []const u8, start_pos: usize) ?usize {
        var p = start_pos;
        while (std.mem.indexOfPos(u8, self.buffer, p, key)) |pos| {
            if (pos > 0 and self.buffer[pos - 1] == '"' and pos + key.len < self.buffer.len and self.buffer[pos + key.len] == '"') {
                return pos;
            }
            p = pos + 1;
        }
        return null;
    }

    fn skipWhitespace(self: *JsonScanner) void {
        while (self.pos < self.buffer.len and std.ascii.isWhitespace(self.buffer[self.pos])) {
            self.pos += 1;
        }
    }

    fn findString(self: *JsonScanner, key: []const u8, parent: ?[]const u8) ![]const u8 {
        const start = if (parent != null) @as(usize, 0) else self.pos;
        const k_pos = if (parent) |p| blk: {
            const p_pos = self.findKey(p, 0) orelse return error.KeyNotFound;
            break :blk self.findKey(key, p_pos + p.len) orelse return error.KeyNotFound;
        } else (self.findKey(key, start) orelse return error.KeyNotFound);

        self.pos = k_pos + key.len + 1;
        self.skipWhitespace();
        if (self.pos < self.buffer.len and self.buffer[self.pos] == ':') {
            self.pos += 1;
            self.skipWhitespace();
            if (self.pos < self.buffer.len and self.buffer[self.pos] == '"') {
                const s = self.pos + 1;
                if (std.mem.indexOfPos(u8, self.buffer, s, "\"")) |end| {
                    self.pos = end + 1;
                    return self.buffer[s..end];
                }
            }
        }
        return error.InvalidJson;
    }

    fn findFloat(self: *JsonScanner, key: []const u8, parent: ?[]const u8) !f64 {
        const start = if (parent != null) @as(usize, 0) else self.pos;
        const k_pos = if (parent) |p| blk: {
            const p_pos = self.findKey(p, 0) orelse return error.KeyNotFound;
            break :blk self.findKey(key, p_pos + p.len) orelse return error.KeyNotFound;
        } else (self.findKey(key, start) orelse return error.KeyNotFound);

        self.pos = k_pos + key.len + 1;
        self.skipWhitespace();
        if (self.pos < self.buffer.len and self.buffer[self.pos] == ':') {
            self.pos += 1;
            self.skipWhitespace();
            const s = self.pos;
            while (self.pos < self.buffer.len and (std.ascii.isDigit(self.buffer[self.pos]) or self.buffer[self.pos] == '.' or self.buffer[self.pos] == '-')) {
                self.pos += 1;
            }
            if (s == self.pos) return error.InvalidJson;
            return try std.fmt.parseFloat(f64, self.buffer[s..self.pos]);
        }
        return error.InvalidJson;
    }

    fn findInt(self: *JsonScanner, key: []const u8) !i64 {
        if (self.findKey(key, self.pos)) |k_pos| {
            self.pos = k_pos + key.len + 1;
            self.skipWhitespace();
            if (self.pos < self.buffer.len and self.buffer[self.pos] == ':') {
                self.pos += 1;
                self.skipWhitespace();
                const s = self.pos;
                while (self.pos < self.buffer.len and (std.ascii.isDigit(self.buffer[self.pos]) or self.buffer[self.pos] == '-')) {
                    self.pos += 1;
                }
                if (s == self.pos) return error.InvalidJson;
                return try std.fmt.parseInt(i64, self.buffer[s..self.pos], 10);
            }
        }
        return error.KeyNotFound;
    }

    fn findBool(self: *JsonScanner, key: []const u8) !bool {
        if (self.findKey(key, self.pos)) |k_pos| {
            self.pos = k_pos + key.len + 1;
            self.skipWhitespace();
            if (self.pos < self.buffer.len and self.buffer[self.pos] == ':') {
                self.pos += 1;
                self.skipWhitespace();
                if (std.mem.startsWith(u8, self.buffer[self.pos..], "true")) {
                    self.pos += 4;
                    return true;
                } else if (std.mem.startsWith(u8, self.buffer[self.pos..], "false")) {
                    self.pos += 5;
                    return false;
                }
            }
        }
        return error.KeyNotFound;
    }

    fn checkMerchantKnown(self: *JsonScanner, merchant_id: []const u8) !bool {
        if (self.findKey("known_merchants", 0)) |k_pos| {
            self.pos = k_pos + 15 + 1;
            self.skipWhitespace();
            if (self.pos < self.buffer.len and self.buffer[self.pos] == ':') {
                self.pos += 1;
                self.skipWhitespace();
                if (self.pos < self.buffer.len and self.buffer[self.pos] == '[') {
                    self.pos += 1;
                    while (self.pos < self.buffer.len and self.buffer[self.pos] != ']') {
                        self.skipWhitespace();
                        if (self.pos < self.buffer.len and self.buffer[self.pos] == '"') {
                            const s = self.pos + 1;
                            if (std.mem.indexOfPos(u8, self.buffer, s, "\"")) |end| {
                                const entry = self.buffer[s..end];
                                if (std.mem.eql(u8, entry, merchant_id)) {
                                    return true;
                                }
                                self.pos = end + 1;
                            } else return error.InvalidJson;
                        } else {
                            self.pos += 1;
                        }
                        self.skipWhitespace();
                        if (self.pos < self.buffer.len and self.buffer[self.pos] == ',') {
                            self.pos += 1;
                        }
                    }
                }
            }
        }
        return false;
    }
};

/// Parsed transaction payload matching the Rinha JSON schema.
/// All string slices borrow from the original input buffer.
pub const TransactionPayload = struct {
    transaction: struct {
        amount: f64,
        installments: i32,
        requested_at: []const u8,
    },
    customer: struct {
        avg_amount: f64,
        tx_count_24h: i32,
        is_merchant_known: bool,
    },
    merchant: struct {
        id: []const u8,
        mcc: []const u8,
        avg_amount: f64,
    },
    terminal: struct {
        is_online: bool,
        card_present: bool,
        km_from_home: f64,
    },
    last_transaction: ?struct {
        timestamp: []const u8,
        km_from_current: f64,
    },
};

const testing = std.testing;

test "custom JSON scanner extracts fields correctly" {
    const json_text =
        \\{
        \\  "id": "test-123",
        \\  "transaction": {
        \\    "amount": 123.45,
        \\    "installments": 3,
        \\    "requested_at": "2026-03-11T18:45:53Z"
        \\  },
        \\  "customer": {
        \\    "avg_amount": 100.0,
        \\    "tx_count_24h": 5,
        \\    "known_merchants": ["M-1", "M-2"]
        \\  },
        \\  "merchant": {
        \\    "id": "M-1",
        \\    "mcc": "5411",
        \\    "avg_amount": 50.0
        \\  },
        \\  "terminal": {
        \\    "is_online": true,
        \\    "card_present": false,
        \\    "km_from_home": 10.5
        \\  },
        \\  "last_transaction": {
        \\    "timestamp": "2026-03-11T15:30:00Z",
        \\    "km_from_current": 5.0
        \\  }
        \\}
    ;

    var scanner = JsonScanner.init(json_text);
    const payload = try scanner.scan();

    try testing.expectEqual(@as(f64, 123.45), payload.transaction.amount);
    try testing.expectEqual(@as(i32, 3), payload.transaction.installments);
    try testing.expectEqualStrings("2026-03-11T18:45:53Z", payload.transaction.requested_at);

    try testing.expectEqual(@as(f64, 100.0), payload.customer.avg_amount);
    try testing.expectEqual(@as(i32, 5), payload.customer.tx_count_24h);
    try testing.expectEqual(true, payload.customer.is_merchant_known);

    try testing.expectEqualStrings("M-1", payload.merchant.id);
    try testing.expectEqualStrings("5411", payload.merchant.mcc);
    try testing.expectEqual(@as(f64, 50.0), payload.merchant.avg_amount);

    try testing.expectEqual(true, payload.terminal.is_online);
    try testing.expectEqual(false, payload.terminal.card_present);
    try testing.expectEqual(@as(f64, 10.5), payload.terminal.km_from_home);

    try testing.expect(payload.last_transaction != null);
    try testing.expectEqualStrings("2026-03-11T15:30:00Z", payload.last_transaction.?.timestamp);
    try testing.expectEqual(@as(f64, 5.0), payload.last_transaction.?.km_from_current);
}

test "custom JSON scanner handles missing last_transaction" {
    const json_text =
        \\{
        \\  "id": "test-123",
        \\  "transaction": {"amount": 100, "installments": 1, "requested_at": "2026-03-11T18:45:53Z"},
        \\  "customer": {"avg_amount": 100, "tx_count_24h": 1, "known_merchants": []},
        \\  "merchant": {"id": "M-1", "mcc": "5411", "avg_amount": 50},
        \\  "terminal": {"is_online": true, "card_present": true, "km_from_home": 0},
        \\  "last_transaction": null
        \\}
    ;

    var scanner = JsonScanner.init(json_text);
    const payload = try scanner.scan();
    try testing.expect(payload.last_transaction == null);
}
