//! mc lint (semantic pass) — Run clang-tidy and reformat diagnostics.
//! Diagnostic output formatting inspired by DonIsaac/zlint (MIT License)
//! https://github.com/DonIsaac/zlint
//! Adapted for C/clang-tidy diagnostics. Original: src/Error.zig, MIT © Don Isaac.

const std = @import("std");
const toml = @import("toml");
const fmt_pkg = @import("fmt"); // for findTool

const DEFAULT_CHECKS =
    "-*, bugprone-*, clang-analyzer-*, readability-*, " ++
    "-bugprone-easily-swappable-parameters, " ++
    "-readability-identifier-length";

pub const RunArgs = struct {
    files: []const []const u8,
    project_root: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// Entry point called by mc.zig for the clang-tidy semantic pass.
/// Returns exit code: 0 = clean, 1 = issues found or tool missing.
pub fn run(ra: RunArgs) !u8 {
    const alloc = ra.allocator;

    if (ra.files.len == 0) {
        var buffer: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(ra.io, &buffer);
        try stderr.interface.writeAll("mc lint: no files specified\n");
        try stderr.interface.flush();
        return 1;
    }

    const cfg = try loadConfig(ra.io, ra.project_root, alloc);
    defer alloc.free(cfg.checks);
    defer alloc.free(cfg.header_filter);

    const clang_tidy = fmt_pkg.findTool(ra.io, "clang-tidy", alloc) catch {
        var buffer: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(ra.io, &buffer);
        try stderr.interface.writeAll("mc lint: clang-tidy not found on PATH or vendor/tools/\nRun: just fetch-tools\n");
        try stderr.interface.flush();
        return 1;
    };
    defer alloc.free(clang_tidy);

    const db_arg: ?[]const u8 = blk: {
        const db = try std.fs.path.join(alloc, &.{ ra.project_root, ".mccache", "compile_commands.json" });
        defer alloc.free(db);
        std.Io.Dir.cwd().access(ra.io, db, .{}) catch break :blk null;
        break :blk try std.fs.path.join(alloc, &.{ ra.project_root, ".mccache" });
    };
    defer if (db_arg) |d| alloc.free(d);

    var exit_code: u8 = 0;
    for (ra.files) |file| {
        const code = try runOnFile(ra.io, file, clang_tidy, &cfg, db_arg, ra.project_root, alloc);
        if (code != 0) exit_code = code;
    }
    return exit_code;
}

const Config = struct {
    checks: []const u8,
    header_filter: []const u8,
    warnings_as_errors: bool,
};

fn loadConfig(io: std.Io, project_root: []const u8, alloc: std.mem.Allocator) !Config {
    const toml_path = try std.fs.path.join(alloc, &.{ project_root, "mc.toml" });
    defer alloc.free(toml_path);

    if (std.Io.Dir.cwd().readFileAlloc(io, toml_path, alloc, .unlimited)) |src| {
        defer alloc.free(src);
        if (toml.parse(src, alloc)) |*doc| {
            defer @constCast(doc).deinit();
            if (doc.section("lint")) |lint_sec| {
                return .{
                    .checks = try alloc.dupe(u8, lint_sec.getString("checks") orelse DEFAULT_CHECKS),
                    .header_filter = try alloc.dupe(u8, lint_sec.getString("header_filter") orelse ".*"),
                    .warnings_as_errors = std.mem.eql(u8, lint_sec.getString("warnings_as_errors") orelse "", "true"),
                };
            }
        } else |_| {}
    } else |_| {}

    return .{
        .checks = try alloc.dupe(u8, DEFAULT_CHECKS),
        .header_filter = try alloc.dupe(u8, ".*"),
        .warnings_as_errors = false,
    };
}

fn runOnFile(
    io: std.Io,
    file: []const u8,
    clang_tidy: []const u8,
    cfg: *const Config,
    db_dir: ?[]const u8,
    project_root: []const u8,
    alloc: std.mem.Allocator,
) !u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);

    try argv.append(alloc, clang_tidy);
    try argv.append(alloc, file);

    const checks_arg = try std.fmt.allocPrint(alloc, "--checks={s}", .{cfg.checks});
    defer alloc.free(checks_arg);
    try argv.append(alloc, checks_arg);

    const header_arg = try std.fmt.allocPrint(alloc, "--header-filter={s}", .{cfg.header_filter});
    defer alloc.free(header_arg);
    try argv.append(alloc, header_arg);

    if (db_dir) |d| {
        const db_arg = try std.fmt.allocPrint(alloc, "-p={s}", .{d});
        defer alloc.free(db_arg);
        try argv.append(alloc, db_arg);
    } else {
        try argv.append(alloc, "--");
    }

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var r_out = child.stdout.?.reader(io, &out_buf);
    var r_err = child.stderr.?.reader(io, &err_buf);

    const raw_out = try r_out.interface.allocRemaining(alloc, .limited(4 * 1024 * 1024));
    defer alloc.free(raw_out);
    const raw_err = try r_err.interface.allocRemaining(alloc, .limited(1024 * 1024));
    defer alloc.free(raw_err);

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try reformatDiagnostics(&stderr.interface, raw_out, project_root, false, alloc);
    if (raw_err.len > 0) try stderr.interface.writeAll(raw_err);
    try stderr.interface.flush();

    return exit_code;
}

fn reformatDiagnostics(
    writer: anytype,
    input: []const u8,
    project_root: []const u8,
    use_color: bool,
    alloc: std.mem.Allocator,
) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (parseDiagnosticLine(line, alloc)) |*d| {
            defer d.deinit(alloc);

            const rel = if (std.mem.startsWith(u8, d.file, project_root))
                d.file[project_root.len + 1 ..]
            else
                d.file;

            if (use_color) {
                const color = levelColor(d.level);
                try writer.writeAll(color);
                try writer.writeAll(d.level);
                try writer.writeAll("\x1b[0m");
            } else {
                try writer.writeAll(d.level);
            }

            if (d.check.len > 0) {
                try writer.print("[{s}]", .{d.check});
            }
            try writer.print(": {s}\n", .{d.message});
            try writer.print("  --> {s}:{s}:{s}\n", .{ rel, d.line_num, d.col_num });

            if (lines.next()) |src_line| {
                if (lines.next()) |caret_line| {
                    const ln_trimmed = std.mem.trimStart(u8, src_line, " ");
                    try writer.writeAll("   |\n");
                    try writer.print("{s:>4} | {s}\n", .{ d.line_num, ln_trimmed });
                    const caret_trimmed = std.mem.trimStart(u8, caret_line, " ");
                    try writer.print("   | {s}\n\n", .{caret_trimmed});
                }
            }
        }
    }
}

const DiagnosticLine = struct {
    file: []const u8,
    line_num: []const u8,
    col_num: []const u8,
    level: []const u8,
    message: []const u8,
    check: []const u8,

    fn deinit(self: *const DiagnosticLine, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }
};

fn parseDiagnosticLine(line: []const u8, alloc: std.mem.Allocator) ?DiagnosticLine {
    _ = alloc;
    var i: usize = 0;
    var file_end: ?usize = null;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;
        if (i == 1 and std.ascii.isAlphabetic(line[0])) continue;
        const rest = line[i + 1 ..];
        var j: usize = 0;
        while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) {}
        if (j > 0 and j < rest.len and rest[j] == ':') {
            file_end = i;
            break;
        }
    }
    const fe = file_end orelse return null;
    const file = line[0..fe];
    const after_file = line[fe + 1 ..];

    var j: usize = 0;
    while (j < after_file.len and std.ascii.isDigit(after_file[j])) : (j += 1) {}
    if (j == 0 or j >= after_file.len or after_file[j] != ':') return null;
    const line_num = after_file[0..j];
    const after_line = after_file[j + 1 ..];

    var k: usize = 0;
    while (k < after_line.len and std.ascii.isDigit(after_line[k])) : (k += 1) {}
    if (k == 0 or k >= after_line.len or after_line[k] != ':') return null;
    const col_num = after_line[0..k];
    const after_col = std.mem.trimStart(u8, after_line[k + 1 ..], " ");

    const levels = [_][]const u8{ "error", "warning", "note", "fatal error" };
    var level: []const u8 = "";
    var after_level: []const u8 = "";
    for (levels) |lv| {
        if (std.mem.startsWith(u8, after_col, lv) and
            after_col.len > lv.len and after_col[lv.len] == ':')
        {
            level = lv;
            after_level = std.mem.trimStart(u8, after_col[lv.len + 1 ..], " ");
            break;
        }
    }
    if (level.len == 0) return null;

    var message: []const u8 = after_level;
    var check: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, after_level, '[')) |lb| {
        if (after_level[after_level.len - 1] == ']') {
            check = after_level[lb + 1 .. after_level.len - 1];
            message = std.mem.trimEnd(u8, after_level[0..lb], " ");
        }
    }

    return .{
        .file = file,
        .line_num = line_num,
        .col_num = col_num,
        .level = level,
        .message = message,
        .check = check,
    };
}

fn levelColor(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "error") or std.mem.eql(u8, level, "fatal error"))
        return "\x1b[1;31m";
    if (std.mem.eql(u8, level, "warning"))
        return "\x1b[1;33m";
    return "\x1b[2m";
}
