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
            var val_it = table.entries.valueIterator();
            while (val_it.next()) |v| {
                switch (v.*) {
                    .array => |a| self.allocator.free(a),
                    else => {},
                }
            }
            table.entries.deinit(self.allocator);
            self.allocator.free(table.section);
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

    pub fn root(self: *const Document) ?*const Table {
        return self.section("");
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

    var root_entries: std.StringHashMapUnmanaged(Value) = .empty;
    errdefer root_entries.deinit(allocator);
    var it = parsed.value.iterator();
    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .table => |sec_table| try collectTable(allocator, entry.key_ptr.*, sec_table, &tables),
            else => try root_entries.put(allocator, entry.key_ptr.*, try convertValue(entry.value_ptr.*, allocator)),
        }
    }
    if (root_entries.count() != 0) {
        try tables.append(allocator, .{ .section = try allocator.dupe(u8, ""), .entries = root_entries });
    } else root_entries.deinit(allocator);

    return .{
        .tables = try tables.toOwnedSlice(allocator),
        .allocator = allocator,
        .parsed = parsed,
    };
}

/// Flatten one TOML table into a `Table` named `name` (its non-table keys)
/// plus one recursive `Table` per nested sub-table, dotted onto `name`
/// (`[build.lua]` becomes a section literally named `"build.lua"`, found
/// via `Document.section("build.lua")`).
fn collectTable(
    allocator: std.mem.Allocator,
    name: []const u8,
    table: *sam701_toml.Table,
    out: *std.ArrayList(Table),
) error{OutOfMemory}!void {
    var entries: std.StringHashMapUnmanaged(Value) = .empty;
    errdefer entries.deinit(allocator);

    var it = table.iterator();
    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .table => |nested| {
                const nested_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, kv.key_ptr.* });
                defer allocator.free(nested_name);
                try collectTable(allocator, nested_name, nested, out);
            },
            else => {
                const val = try convertValue(kv.value_ptr.*, allocator);
                try entries.put(allocator, kv.key_ptr.*, val);
            },
        }
    }

    try out.append(allocator, .{
        .section = try allocator.dupe(u8, name),
        .entries = entries,
    });
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

test "parse root dependency URLs" {
    var doc = try parse("dependencies = [\"https://forge.example/acme/json\"]\n[project]\nname = \"app\"\n", std.testing.allocator);
    defer doc.deinit();
    try std.testing.expectEqualStrings("https://forge.example/acme/json", doc.root().?.getArray("dependencies").?[0]);
}

test "parse nested [build.<name>] sub-tables" {
    const src =
        \\[project]
        \\name = "lua"
        \\
        \\[build]
        \\outputs = ["lua", "luac"]
        \\defines = ["LUA_USE_JUMPTABLE=0"]
        \\
        \\[build.lua]
        \\main = "src/lua.c"
        \\
        \\[build.luac]
        \\main = "src/luac.c"
        \\
    ;
    var doc = try parse(src, std.testing.allocator);
    defer doc.deinit();

    const build_sec = doc.section("build").?;
    try std.testing.expectEqualStrings("LUA_USE_JUMPTABLE=0", build_sec.getArray("defines").?[0]);
    try std.testing.expectEqualStrings("lua", build_sec.getArray("outputs").?[0]);
    try std.testing.expectEqualStrings("luac", build_sec.getArray("outputs").?[1]);
    // [build.lua] must not leak into [build]'s own entries as a mangled value.
    try std.testing.expect(build_sec.get("lua") == null);

    const lua_sec = doc.section("build.lua").?;
    try std.testing.expectEqualStrings("src/lua.c", lua_sec.getString("main").?);
    const luac_sec = doc.section("build.luac").?;
    try std.testing.expectEqualStrings("src/luac.c", luac_sec.getString("main").?);
}
