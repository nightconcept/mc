const std = @import("std");
const Io = std.Io;

const fmt_pkg = @import("fmt");
const lint_pkg = @import("lint");
const lsp_pkg = @import("lsp");

extern fn c2m_main(argc: c_int, argv: [*c][*c]u8, envp: [*c][*c]u8) c_int;

const usage =
    \\mc (ModC) -- MIR/c2mir-backed C compiler and toolchain
    \\Usage:
    \\  mc file.c [args]              Compile and run (JIT via c2mir)
    \\  mc run file.c -- [args]       Compile and run
    \\  mc build [args]               Build artifact (-c/-S/-o, ...)
    \\  mc lint [--syntax-only] file  Lint (syntax gate + clang-tidy)
    \\  mc fmt [--check] [files|.]    Format with clang-format
    \\  mc lsp                        Start LSP server (clangd bridge)
    \\  mc init                       Scaffold mc.toml in current directory
    \\  mc c2m [args]                 Raw c2mir interface
    \\
;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("mc: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len == 1 or (args.len == 2 and (eql(args[1], "help") or eql(args[1], "--help") or eql(args[1], "-h")))) {
        var buffer: [1024]u8 = undefined;
        var stdout = Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll(usage);
        try stdout.interface.flush();
        return 0;
    }

    const sub = args[1];

    if (eql(sub, "fmt")) {
        const project_root = try findProjectRoot(init.io, arena);
        return fmt_pkg.run(.{
            .args = args[2..],
            .project_root = project_root,
            .allocator = arena,
            .io = init.io,
        });
    }

    if (eql(sub, "lsp")) {
        return lsp_pkg.run(init.io, arena);
    }

    if (eql(sub, "init")) {
        return runInit(init.io, arena);
    }

    if (eql(sub, "lint")) {
        var syntax_only = false;
        var files: std.ArrayList([:0]const u8) = .empty;
        for (args[2..]) |arg| {
            if (eql(arg, "--syntax-only")) {
                syntax_only = true;
            } else {
                try files.append(arena, arg);
            }
        }

        var c2m_argv: std.ArrayList([:0]const u8) = .empty;
        try c2m_argv.append(arena, "-fsyntax-only");
        try c2m_argv.appendSlice(arena, files.items);

        var argv_buf = try arena.alloc([*c]u8, c2m_argv.items.len + 1);
        argv_buf[0] = @constCast(args[0].ptr);
        for (c2m_argv.items, 1..) |arg, i| argv_buf[i] = @constCast(arg.ptr);
        const syntax_rc = c2m_main(@intCast(argv_buf.len), argv_buf.ptr, null);
        if (syntax_rc != 0) return @intCast(syntax_rc);
        if (syntax_only) return 0;

        const project_root = try findProjectRoot(init.io, arena);
        var plain_files: std.ArrayList([]const u8) = .empty;
        for (files.items) |f| try plain_files.append(arena, f);
        return lint_pkg.run(.{
            .files = plain_files.items,
            .project_root = project_root,
            .allocator = arena,
            .io = init.io,
        });
    }

    const routed = try route(arena, args[1..]);
    var argv = try arena.alloc([*c]u8, routed.len + 1);
    argv[0] = @constCast(args[0].ptr);
    for (routed, 1..) |arg, i| argv[i] = @constCast(arg.ptr);
    return @intCast(c2m_main(@intCast(argv.len), argv.ptr, null));
}

fn route(arena: std.mem.Allocator, args: []const [:0]const u8) ![]const [:0]const u8 {
    var out: std.ArrayList([:0]const u8) = .empty;

    if (eql(args[0], "c2m") or eql(args[0], "build")) {
        try out.appendSlice(arena, args[1..]);
    } else {
        const start: usize = if (eql(args[0], "run")) 1 else 0;
        var delimiter = true;
        if (args[start..].len == 0) return error.MissingSourceFile;
        try out.append(arena, args[start]);
        try out.append(arena, "-eg");
        for (args[start + 1 ..]) |arg| {
            if (delimiter and eql(arg, "--")) {
                delimiter = false;
                continue;
            }
            try out.append(arena, arg);
        }
    }
    return out.toOwnedSlice(arena);
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

fn runInit(io: std.Io, allocator: std.mem.Allocator) !u8 {
    var buffer: [512]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);

    if (fmt_pkg.fileExists(io, "mc.toml")) {
        try stderr.interface.writeAll("mc init: mc.toml already exists\n");
        try stderr.interface.flush();
        return 1;
    }
    try initScaffold(io, allocator);
    return 0;
}

fn initScaffold(
    io: std.Io,
    allocator: std.mem.Allocator,
) !void {
    var authors_str: std.ArrayList(u8) = .empty;
    defer authors_str.deinit(allocator);
    try authors_str.appendSlice(allocator, "[]");

    const content = try std.fmt.allocPrint(allocator,
        \\# mc.toml — generated by mc init
        \\
        \\[project]
        \\name    = "myproject"
        \\version = "0.1.0"
        \\license = "MIT"
        \\authors = []
        \\
        \\[build]
        \\# c_standard   = "c11"          # -std= flag
        \\# include_dirs = ["include"]    # -I flags
        \\# defines      = []             # -D flags: ["FOO=1"]
        \\# sources      = ["src/**/*.c"] # glob patterns (used by lint + lsp)
        \\
        \\[fmt]
        \\# All keys mirror clang-format YAML names.
        \\# Delete this block to use mc defaults:
        \\#
        \\# BasedOnStyle                     = "LLVM"
        \\# ColumnLimit                      = 120
        \\# IndentWidth                      = 4
        \\# UseTab                           = "Never"
        \\# PointerAlignment                 = "Right"
        \\# BreakBeforeBraces                = "Attach"
        \\# AllowShortFunctionsOnASingleLine = "Inline"
        \\# AlignConsecutiveMacros           = "Consecutive"
        \\# AlignConsecutiveAssignments      = "None"
        \\# AlignConsecutiveDeclarations     = "None"
        \\# SortIncludes                     = "Never"
        \\# IncludeBlocks                    = "Preserve"
        \\
        \\[lint]
        \\# Delete this block to use mc defaults:
        \\#
        \\# checks             = "-*, bugprone-*, clang-analyzer-*, readability-*, -bugprone-easily-swappable-parameters, -readability-identifier-length"
        \\# warnings_as_errors = ""
        \\# header_filter      = ".*"
        \\
        \\[lsp]
        \\# clangd_args = []   # extra flags forwarded to clangd
        \\
    , .{});
    defer allocator.free(content);

    const file = try std.Io.Dir.cwd().createFile(io, "mc.toml", .{ .exclusive = true });
    defer file.close(io);
    var file_buf: [1024]u8 = undefined;
    var w = file.writer(io, &file_buf);
    try w.interface.writeAll(content);
    try w.interface.flush();

    var buffer: [512]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll("\nCreated mc.toml\n");
    try stderr.interface.flush();
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "routes commands" {
    _ = fmt_pkg;
    _ = lint_pkg;
    _ = lsp_pkg;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shorthand = try route(arena, &.{"hello.c"});
    try std.testing.expectEqualStrings("hello.c", shorthand[0]);
    try std.testing.expectEqualStrings("-eg", shorthand[1]);

    const build = try route(arena, &.{ "build", "hello.c", "-o", "hello" });
    try std.testing.expectEqualStrings("hello.c", build[0]);
    try std.testing.expectEqualStrings("-o", build[1]);

    const run_args = try route(arena, &.{ "run", "hello.c", "--", "one" });
    try std.testing.expectEqualStrings("hello.c", run_args[0]);
    try std.testing.expectEqualStrings("-eg", run_args[1]);
    try std.testing.expectEqualStrings("one", run_args[2]);
}
