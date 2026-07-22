//! TOML parser for mc.toml config files powered by sam701/zig-toml.

const std = @import("std");
pub const sam701_toml = @import("toml");

pub const Value = union(enum) {
    string: []const u8,
    array: []const []const u8,
    integer: i64,

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?[]const []const u8 {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }
};

pub const Table = struct {
    section: []const u8,
    entries: std.StringHashMapUnmanaged(Value),

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getString(self: *const Table, key: []const u8) ?[]const u8 {
        const v = self.entries.get(key) orelse return null;
        return v.asString();
    }

    pub fn getArray(self: *const Table, key: []const u8) ?[]const []const u8 {
        const v = self.entries.get(key) orelse return null;
        return v.asArray();
    }
};

pub const Document = struct {
    tables: []Table,
    allocator: std.mem.Allocator,
    parsed: sam701_toml.Parsed(sam701_toml.Table),

    pub fn deinit(self: *Document) void {
        for (self.tables) |*table| {
            table.entries.deinit(self.allocator);
        }
        self.allocator.free(self.tables);
        self.parsed.deinit();
    }

    /// Find a section by name. Returns null if not found.
    pub fn section(self: *const Document, name: []const u8) ?*const Table {
        for (self.tables) |*table| {
            if (std.mem.eql(u8, table.section, name)) return table;
        }
        return null;
    }
};

pub const ParseError = error{
    InvalidSyntax,
    UnterminatedString,
    UnterminatedArray,
    OutOfMemory,
};

/// Parse TOML source text using sam701/zig-toml.
pub fn parse(source: []const u8, allocator: std.mem.Allocator) ParseError!Document {
    var parser = sam701_toml.Parser(sam701_toml.Table).init(allocator);
    defer parser.deinit();

    var parsed = parser.parseString(source) catch return error.InvalidSyntax;
    errdefer parsed.deinit();

    var tables: std.ArrayList(Table) = .empty;
    errdefer {
        for (tables.items) |*t| t.entries.deinit(allocator);
        tables.deinit(allocator);
    }

    var it = parsed.value.iterator();
    while (it.next()) |entry| {
        const sec_name = entry.key_ptr.*;
        switch (entry.value_ptr.*) {
            .table => |sec_table| {
                var entries: std.StringHashMapUnmanaged(Value) = .empty;
                errdefer entries.deinit(allocator);

                var sec_it = sec_table.iterator();
                while (sec_it.next()) |kv| {
                    const key = kv.key_ptr.*;
                    const val = try convertValue(kv.value_ptr.*, allocator);
                    try entries.put(allocator, key, val);
                }

                try tables.append(allocator, .{
                    .section = sec_name,
                    .entries = entries,
                });
            },
            else => {},
        }
    }

    return .{
        .tables = try tables.toOwnedSlice(allocator),
        .allocator = allocator,
        .parsed = parsed,
    };
}

fn convertValue(val: sam701_toml.Value, allocator: std.mem.Allocator) error{OutOfMemory}!Value {
    switch (val) {
        .string => |s| return .{ .string = s },
        .integer => |i| return .{ .integer = i },
        .array => |ar| {
            var items: std.ArrayList([]const u8) = .empty;
            errdefer items.deinit(allocator);
            for (ar.items) |elem| {
                switch (elem) {
                    .string => |s| try items.append(allocator, s),
                    else => {},
                }
            }
            return .{ .array = try items.toOwnedSlice(allocator) };
        },
        else => return .{ .string = "" },
    }
}

test "parse basic mc.toml" {
    const src =
        \\[project]
        \\name = "myapp"
        \\version = "0.1.0"
        \\license = "MIT"
        \\authors = []
        \\[fmt]
        \\ColumnLimit = 120
        \\[lint]
        \\header_filter = ".*"
        \\
    ;
    var doc = try parse(src, std.testing.allocator);
    defer doc.deinit();

    const proj = doc.section("project").?;
    try std.testing.expectEqualStrings("myapp", proj.getString("name").?);
    try std.testing.expectEqualStrings("MIT", proj.getString("license").?);

    const fmt_sec = doc.section("fmt").?;
    try std.testing.expectEqual(@as(i64, 120), fmt_sec.get("ColumnLimit").?.asInteger().?);
}
