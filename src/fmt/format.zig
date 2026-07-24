//! mc fmt — Format C/H files using clang-format.
//! Reads mc.toml [fmt] section to build clang-format style string.
//! Falls back to .clang-format file, then built-in defaults.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

/// Default clang-format style used when no .clang-format or [fmt] config exists.
const DEFAULT_STYLE =
    "{BasedOnStyle: LLVM, ColumnLimit: 120, IndentWidth: 4, UseTab: Never, " ++
    "PointerAlignment: Right, BreakBeforeBraces: Attach, " ++
    "AllowShortFunctionsOnASingleLine: Inline, AlignConsecutiveMacros: Consecutive, " ++
    "SortIncludes: Never, IncludeBlocks: Preserve}";

pub const RunArgs = struct {
    args: []const [:0]const u8,
    project_root: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// Entry point called by mc.zig for `mc fmt`.
pub fn run(ra: RunArgs) !u8 {
    const alloc = ra.allocator;
    var check_only = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);

    for (ra.args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buffer: [512]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(ra.io, &buffer);
            try stderr.interface.writeAll(
                "mc fmt [--check] [file.c ...]\n" ++
                    "  Format C/H source files using clang-format.\n" ++
                    "  --check  Exit 1 if any file would be changed (for CI).\n" ++
                    "  .        Format all .c/.h files under current directory.\n",
            );
            try stderr.interface.flush();
            return 0;
        } else {
            try paths.append(alloc, arg);
        }
    }

    if (paths.items.len == 0 or (paths.items.len == 1 and std.mem.eql(u8, paths.items[0], "."))) {
        paths.clearRetainingCapacity();
        try collectCFiles(ra.io, ra.project_root, &paths, alloc);
    }

    if (paths.items.len == 0) {
        return 0;
    }

    const style = try resolveStyle(ra.io, ra.project_root, alloc);
    defer alloc.free(style);

    return runClangFormat(ra.io, paths.items, style, check_only, alloc);
}

fn collectCFiles(io: std.Io, root: []const u8, out: *std.ArrayList([]const u8), alloc: std.mem.Allocator) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.basename;
        if (std.mem.endsWith(u8, name, ".c") or std.mem.endsWith(u8, name, ".h")) {
            const full = try std.fs.path.join(alloc, &.{ root, entry.path });
            try out.append(alloc, full);
        }
    }
}

fn resolveStyle(io: std.Io, project_root: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const clang_fmt_path = try std.fs.path.join(alloc, &.{ project_root, ".clang-format" });
    defer alloc.free(clang_fmt_path);
    if (fileExists(io, clang_fmt_path)) {
        return alloc.dupe(u8, "file");
    }

    const toml_path = try std.fs.path.join(alloc, &.{ project_root, "mc.toml" });
    defer alloc.free(toml_path);
    if (fileExists(io, toml_path)) {
        const src = std.Io.Dir.cwd().readFileAlloc(io, toml_path, alloc, .unlimited) catch null;
        if (src) |s| {
            defer alloc.free(s);
            if (toml.parse(s, alloc)) |*doc| {
                defer @constCast(doc).deinit();
                if (doc.section("fmt")) |fmt_sec| {
                    return buildStyleFromTable(fmt_sec, alloc) catch alloc.dupe(u8, DEFAULT_STYLE);
                }
            } else |_| {}
        }
    }

    return alloc.dupe(u8, DEFAULT_STYLE);
}

fn buildStyleFromTable(table: *const toml.Table, alloc: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.append(alloc, '{');
    var first = true;
    const has_base = table.get("BasedOnStyle") != null;
    if (!has_base) {
        try buf.appendSlice(alloc, "BasedOnStyle: LLVM");
        first = false;
    }
    var it = table.entries.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(alloc, ", ");
        first = false;
        try buf.appendSlice(alloc, entry.key_ptr.*);
        try buf.append(alloc, ':');
        try buf.append(alloc, ' ');
        switch (entry.value_ptr.*) {
            .string => |s| try buf.appendSlice(alloc, s),
            .integer => |i| {
                var tmp: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch "";
                try buf.appendSlice(alloc, formatted);
            },
            else => {},
        }
    }
    try buf.append(alloc, '}');
    return buf.toOwnedSlice(alloc);
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn runClangFormat(
    io: std.Io,
    paths: []const []const u8,
    style: []const u8,
    check_only: bool,
    alloc: std.mem.Allocator,
) !u8 {
    const clang_fmt = findTool(io, "clang-format", alloc) catch {
        var buffer: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &buffer);
        try stderr.interface.writeAll("mc fmt: clang-format not found on PATH or .tools/\nRun: just fetch-tools\n");
        try stderr.interface.flush();
        return 1;
    };
    defer alloc.free(clang_fmt);

    const style_arg = try std.fmt.allocPrint(alloc, "--style={s}", .{style});
    defer alloc.free(style_arg);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, clang_fmt);
    try argv.append(alloc, style_arg);
    if (check_only) {
        try argv.append(alloc, "--dry-run");
        try argv.append(alloc, "--Werror");
    } else {
        try argv.append(alloc, "-i");
    }
    for (paths) |p| try argv.append(alloc, p);

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn findTool(io: std.Io, name: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    // Executables carry a .exe suffix on Windows; the fetched tools in .tools/
    // (and anything on PATH) are e.g. clang-format.exe, so look for that name.
    const exe_name = if (builtin.os.tag == .windows)
        try std.fmt.allocPrint(alloc, "{s}.exe", .{name})
    else
        name;
    defer if (builtin.os.tag == .windows) alloc.free(exe_name);

    if (std.process.Environ.empty.getAlloc(alloc, "PATH")) |path_env| {
        defer alloc.free(path_env);
        var it = std.mem.splitScalar(u8, path_env, if (std.fs.path.sep == '\\') ';' else ':');
        while (it.next()) |dir| {
            const candidate = try std.fs.path.join(alloc, &.{ dir, exe_name });
            defer alloc.free(candidate);
            if (fileExists(io, candidate)) return alloc.dupe(u8, candidate);
        }
    } else |_| {}

    const exe_path = try std.process.executablePathAlloc(io, alloc);
    defer alloc.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    var dir = exe_dir;
    var attempts: u8 = 0;
    while (attempts < 5) : (attempts += 1) {
        const tools_path = try std.fs.path.join(alloc, &.{ dir, ".tools", exe_name });
        defer alloc.free(tools_path);
        if (fileExists(io, tools_path)) return alloc.dupe(u8, tools_path);

        const vendor_path = try std.fs.path.join(alloc, &.{ dir, "vendor", "tools", exe_name });
        defer alloc.free(vendor_path);
        if (fileExists(io, vendor_path)) return alloc.dupe(u8, vendor_path);

        dir = std.fs.path.dirname(dir) orelse break;
    }

    return error.NotFound;
}
