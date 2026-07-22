//! Minimal TOML parser for mc.toml config files.
//! Supports: [sections], string values, string arrays, integers, comments.
//! Does not support: inline tables, multi-line strings, dates, floats.

const std = @import("std");

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
    /// Section name, e.g. "project", "fmt", "lint"
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

    pub fn deinit(self: *Document) void {
        for (self.tables) |*table| {
            table.entries.deinit(self.allocator);
        }
        self.allocator.free(self.tables);
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

/// Parse TOML source text. Caller owns the returned Document and must call deinit().
/// All string values are slices into the original source — do not free source before deinit.
pub fn parse(source: []const u8, allocator: std.mem.Allocator) ParseError!Document {
    var tables: std.ArrayList(Table) = .empty;
    errdefer {
        for (tables.items) |*t| t.entries.deinit(allocator);
        tables.deinit(allocator);
    }

    var current_section: ?[]const u8 = null;
    var current_entries: std.StringHashMapUnmanaged(Value) = .empty;
    errdefer current_entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        const trimmed = std.mem.trim(u8, line, " \t");

        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '[') {
            const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse
                return error.InvalidSyntax;
            const name = std.mem.trim(u8, trimmed[1..close], " \t");

            if (current_section) |prev_name| {
                try tables.append(allocator, .{ .section = prev_name, .entries = current_entries });
                current_entries = .empty;
            }
            current_section = name;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const rest = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        const value_src = stripInlineComment(rest);

        const value = try parseValue(value_src, allocator);
        if (current_section == null) {
            continue;
        }
        try current_entries.put(allocator, key, value);
    }

    if (current_section) |name| {
        try tables.append(allocator, .{ .section = name, .entries = current_entries });
        current_entries = .empty;
    }

    return .{ .tables = try tables.toOwnedSlice(allocator), .allocator = allocator };
}

fn stripInlineComment(s: []const u8) []const u8 {
    var in_string = false;
    var in_array = false;
    for (s, 0..) |c, i| {
        if (c == '"') in_string = !in_string;
        if (!in_string and c == '[') in_array = true;
        if (!in_string and c == ']') in_array = false;
        if (!in_string and !in_array and c == '#') {
            return std.mem.trimEnd(u8, s[0..i], " \t");
        }
    }
    return s;
}

fn parseValue(s: []const u8, allocator: std.mem.Allocator) ParseError!Value {
    if (s.len == 0) return .{ .string = "" };

    if (s[0] == '"') {
        if (s.len < 2 or s[s.len - 1] != '"') return error.UnterminatedString;
        return .{ .string = s[1 .. s.len - 1] };
    }

    if (s[0] == '[') {
        if (s[s.len - 1] != ']') return error.UnterminatedArray;
        const inner = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
        if (inner.len == 0) return .{ .array = &.{} };

        var items: std.ArrayList([]const u8) = .empty;
        errdefer items.deinit(allocator);

        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |elem| {
            const e = std.mem.trim(u8, elem, " \t");
            if (e.len >= 2 and e[0] == '"' and e[e.len - 1] == '"') {
                try items.append(allocator, e[1 .. e.len - 1]);
            } else if (e.len > 0) {
                try items.append(allocator, e);
            }
        }
        return .{ .array = try items.toOwnedSlice(allocator) };
    }

    if (std.fmt.parseInt(i64, s, 10)) |i| {
        return .{ .integer = i };
    } else |_| {}

    return .{ .string = s };
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
