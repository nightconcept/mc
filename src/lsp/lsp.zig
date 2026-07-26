//! mc lsp — LSP bridge: reads mc.toml, generates .mccache/compile_commands.json,
//! spawns clangd and proxies JSON-RPC stdio bidirectionally.

const std = @import("std");
const toml = @import("toml");
const fmt_pkg = @import("fmt"); // for findTool

/// Entry point called by mc.zig for `mc lsp`.
pub fn run(io: std.Io, allocator: std.mem.Allocator) !u8 {
    const project_root = try findProjectRoot(io, allocator);
    defer allocator.free(project_root);

    const build_cfg = try loadBuildConfig(io, project_root, allocator);
    defer build_cfg.deinit(allocator);

    const cache_dir = try std.fs.path.join(allocator, &.{ project_root, ".mccache" });
    defer allocator.free(cache_dir);
    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch {};

    try generateCompileCommands(io, project_root, &build_cfg, cache_dir, allocator);

    const clangd = fmt_pkg.findTool(io, "clangd", allocator) catch {
        var buffer: [512]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        const msg =
            \\{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":1,"message":"mc lsp: clangd not found. Run: just fetch-tools"}}
        ;
        try stdout.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ msg.len, msg });
        try stdout.interface.flush();
        return 1;
    };
    defer allocator.free(clangd);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, clangd);
    const db_arg = try std.fmt.allocPrint(allocator, "--compile-commands-dir={s}", .{cache_dir});
    defer allocator.free(db_arg);
    try argv.append(allocator, db_arg);
    for (build_cfg.clangd_args) |arg| try argv.append(allocator, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const stdin_to_clangd = try std.Thread.spawn(.{}, pumpStream, .{ io, std.Io.File.stdin(), child.stdin.? });
    const clangd_to_stdout = try std.Thread.spawn(.{}, pumpStream, .{ io, child.stdout.?, std.Io.File.stdout() });

    stdin_to_clangd.join();
    clangd_to_stdout.join();

    const term = try child.wait(io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

fn pumpStream(io: std.Io, src: std.Io.File, dst: std.Io.File) void {
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var r = src.reader(io, &read_buf);
    var w = dst.writer(io, &write_buf);
    while (true) {
        const n = r.interface.readSliceShort(&read_buf) catch break;
        if (n == 0) break;
        w.interface.writeAll(read_buf[0..n]) catch break;
        w.interface.flush() catch break;
    }
}

fn findProjectRoot(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const cur = try std.process.currentPathAlloc(io, allocator);
    var dir: []const u8 = cur;
    var attempts: u8 = 20;
    while (attempts > 0) : (attempts -= 1) {
        const toml_path = try std.fs.path.join(allocator, &.{ dir, "mc.toml" });
        defer allocator.free(toml_path);
        if (fmt_pkg.fileExists(io, toml_path)) return dir;
        const parent = std.fs.path.dirname(dir) orelse break;
        const new_dir = try allocator.dupe(u8, parent);
        allocator.free(dir);
        dir = new_dir;
    }
    return dir;
}

const BuildConfig = struct {
    c_standard: []const u8,
    include_dirs: []const []const u8,
    defines: []const []const u8,
    sources: []const []const u8,
    clangd_args: []const []const u8,

    fn deinit(self: *const BuildConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.c_standard);
        for (self.include_dirs) |d| allocator.free(d);
        allocator.free(self.include_dirs);
        for (self.defines) |d| allocator.free(d);
        allocator.free(self.defines);
        for (self.sources) |s| allocator.free(s);
        allocator.free(self.sources);
        for (self.clangd_args) |a| allocator.free(a);
        allocator.free(self.clangd_args);
    }
};

fn dupeStringArray(allocator: std.mem.Allocator, arr: ?[]const []const u8) ![]const []const u8 {
    const items = arr orelse return try allocator.alloc([]const u8, 0);
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, i| {
        out[i] = try allocator.dupe(u8, item);
    }
    return out;
}

fn loadBuildConfig(io: std.Io, project_root: []const u8, allocator: std.mem.Allocator) !BuildConfig {
    const toml_path = try std.fs.path.join(allocator, &.{ project_root, "mc.toml" });
    defer allocator.free(toml_path);

    if (std.Io.Dir.cwd().readFileAlloc(io, toml_path, allocator, .unlimited)) |src| {
        defer allocator.free(src);
        if (toml.parse(src, allocator)) |*doc| {
            defer @constCast(doc).deinit();

            const build_sec = doc.section("build");
            const lsp_sec = doc.section("lsp");

            const std_val = if (build_sec) |s| s.getString("c_standard") orelse "c99" else "c99";
            const inc_val = if (build_sec) |s| s.getArray("include_dirs") else null;
            const def_val = if (build_sec) |s| s.getArray("defines") else null;
            const src_val = if (build_sec) |s| s.getArray("sources") else null;
            const lsp_val = if (lsp_sec) |s| s.getArray("clangd_args") else null;

            return .{
                .c_standard = try allocator.dupe(u8, std_val),
                .include_dirs = try dupeStringArray(allocator, inc_val),
                .defines = try dupeStringArray(allocator, def_val),
                .sources = try dupeStringArray(allocator, src_val),
                .clangd_args = try dupeStringArray(allocator, lsp_val),
            };
        } else |_| {}
    } else |_| {}

    return .{
        .c_standard = try allocator.dupe(u8, "c99"),
        .include_dirs = try allocator.alloc([]const u8, 0),
        .defines = try allocator.alloc([]const u8, 0),
        .sources = try allocator.alloc([]const u8, 0),
        .clangd_args = try allocator.alloc([]const u8, 0),
    };
}

fn normalizePath(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const dup = try allocator.dupe(u8, path);
    for (dup) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return dup;
}

fn generateCompileCommands(
    io: std.Io,
    project_root: []const u8,
    cfg: *const BuildConfig,
    cache_dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var sources: std.ArrayList([]const u8) = .empty;
    defer {
        for (sources.items) |s| allocator.free(s);
        sources.deinit(allocator);
    }

    if (cfg.sources.len > 0) {
        for (cfg.sources) |pattern| {
            try expandSources(io, project_root, pattern, &sources, allocator);
        }
    } else {
        try expandSources(io, project_root, "**/*.c", &sources, allocator);
    }

    var cmd_base: std.ArrayList(u8) = .empty;
    defer cmd_base.deinit(allocator);

    const std_flag = try std.fmt.allocPrint(allocator, "clang -std={s}", .{cfg.c_standard});
    defer allocator.free(std_flag);
    try cmd_base.appendSlice(allocator, std_flag);

    for (cfg.include_dirs) |dir| {
        const inc_flag = try std.fmt.allocPrint(allocator, " -I{s}", .{dir});
        defer allocator.free(inc_flag);
        try cmd_base.appendSlice(allocator, inc_flag);
    }
    for (cfg.defines) |def| {
        const def_flag = try std.fmt.allocPrint(allocator, " -D{s}", .{def});
        defer allocator.free(def_flag);
        try cmd_base.appendSlice(allocator, def_flag);
    }

    const tmp_path = try std.fs.path.join(allocator, &.{ cache_dir, "compile_commands.json.tmp" });
    defer allocator.free(tmp_path);
    const final_path = try std.fs.path.join(allocator, &.{ cache_dir, "compile_commands.json" });
    defer allocator.free(final_path);

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer file.close(io);

    const norm_root = try normalizePath(project_root, allocator);
    defer allocator.free(norm_root);

    var file_buf: [4096]u8 = undefined;
    var w = file.writer(io, &file_buf);
    try w.interface.writeAll("[\n");
    for (sources.items, 0..) |src, idx| {
        const norm_src = try normalizePath(src, allocator);
        defer allocator.free(norm_src);

        try w.interface.writeAll("  {\n");
        const formatted = try std.fmt.allocPrint(allocator,
            \\    "directory": "{s}",
            \\    "file": "{s}",
            \\    "command": "{s} -c {s}"
            \\
        , .{ norm_root, norm_src, cmd_base.items, norm_src });
        defer allocator.free(formatted);
        try w.interface.writeAll(formatted);
        if (idx + 1 < sources.items.len) {
            try w.interface.writeAll("  },\n");
        } else {
            try w.interface.writeAll("  }\n");
        }
    }
    try w.interface.writeAll("]\n");
    try w.interface.flush();

    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), final_path, io);
}

fn expandSources(
    io: std.Io,
    project_root: []const u8,
    pattern: []const u8,
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    _ = pattern;
    var dir = std.Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
        if (std.mem.startsWith(u8, entry.path, "build/")) continue;
        if (std.mem.startsWith(u8, entry.path, "vendor/")) continue;
        if (std.mem.startsWith(u8, entry.path, ".mccache/")) continue;
        const full = try std.fs.path.join(allocator, &.{ project_root, entry.path });
        try out.append(allocator, full);
    }
}
