const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const fmt_pkg = @import("fmt");
const lint_pkg = @import("lint");
const lsp_pkg = @import("lsp");
const runtime_pkg = @import("runtime");
const toml_pkg = @import("toml");

extern fn tcc_main(argc: c_int, argv: [*c][*c]u8) c_int;

const runtime_archive = runtime_pkg.archive;
const tcc_version = std.mem.trim(u8, runtime_pkg.version, " \r\n");

const usage =
    \\mc (ModC) -- TinyCC-backed C compiler and toolchain
    \\Usage:
    \\  mc file.c [args]              Compile and run (JIT via tcc)
    \\  mc run file.c -- [args]       Compile and run
    \\  mc build                      Build the mc.toml project (reads [build])
    \\  mc build [args]               Build artifact (-c/-S/-o, ...)
    \\  mc lint [--syntax-only] file  Lint (syntax gate + clang-tidy)
    \\  mc fmt [--check] [files|.]    Format with clang-format
    \\  mc lsp                        Start LSP server (clangd bridge)
    \\  mc init                       Scaffold mc.toml in current directory
    \\  mc tcc [args]                 Raw tcc interface
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

        // tcc has no -fsyntax-only; -c -o <discard> parses and generates
        // code without linking, which is the same gate intent.
        const discard_obj = if (builtin.os.tag == .windows) "NUL" else "/dev/null";
        const cache = try prepareRuntime(arena, init.io, init.environ_map);

        var tcc_argv: std.ArrayList([:0]const u8) = .empty;
        try tcc_argv.append(arena, try std.fmt.allocPrintSentinel(arena, "-B{s}", .{cache}, 0));
        try tcc_argv.append(arena, "-c");
        try tcc_argv.append(arena, "-o");
        try tcc_argv.append(arena, discard_obj);
        try tcc_argv.appendSlice(arena, files.items);

        var argv_buf = try arena.alloc([*c]u8, tcc_argv.items.len + 1);
        argv_buf[0] = @constCast(args[0].ptr);
        for (tcc_argv.items, 1..) |arg, i| argv_buf[i] = @constCast(arg.ptr);
        const syntax_rc = tcc_main(@intCast(argv_buf.len), argv_buf.ptr);
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

    if (eql(sub, "build") and args.len == 2) {
        const cache = try prepareRuntime(arena, init.io, init.environ_map);
        return projectBuild(arena, init.io, cache);
    }

    const cache = try prepareRuntime(arena, init.io, init.environ_map);
    const routed = try route(arena, cache, args[1..]);
    var argv = try arena.alloc([*c]u8, routed.len + 1);
    argv[0] = @constCast(args[0].ptr);
    for (routed, 1..) |arg, i| argv[i] = @constCast(arg.ptr);
    return @intCast(tcc_main(@intCast(argv.len), argv.ptr));
}

fn route(arena: std.mem.Allocator, cache: []const u8, args: []const [:0]const u8) ![]const [:0]const u8 {
    var out: std.ArrayList([:0]const u8) = .empty;
    try out.append(arena, try std.fmt.allocPrintSentinel(arena, "-B{s}", .{cache}, 0));

    if (eql(args[0], "tcc") or eql(args[0], "build")) {
        try out.appendSlice(arena, args[1..]);
    } else {
        const start: usize = if (eql(args[0], "run")) 1 else 0;
        var delimiter = true;
        if (args[start..].len == 0) return error.MissingSourceFile;
        try out.append(arena, "-run");
        try out.append(arena, args[start]);
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

/// `mc build` with no args: read mc.toml's [project]/[build] sections,
/// Join `base` with a `mc.toml`-supplied relative path, which always uses
/// `/` regardless of host OS (TOML convention) — split on `/` first so each
/// segment joins with the native separator instead of becoming one literal
/// component (which would silently mismatch a native-path built elsewhere,
/// e.g. by a directory walker, on Windows).
fn joinRelative(arena: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(arena, base);
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try parts.append(arena, part);
    }
    return std.fs.path.join(arena, parts.items);
}

/// A `[build]` view that checks a named child section (`[build.<name>]`)
/// before falling back to the top-level `[build]` table, so a multi-output
/// project can share `defines`/`include_dirs`/`c_standard` across outputs
/// while overriding `sources`/`main`/`target` per output.
const BuildView = struct {
    child: ?*const toml_pkg.Table,
    parent: ?*const toml_pkg.Table,

    fn getString(self: BuildView, key: []const u8) ?[]const u8 {
        if (self.child) |c| if (c.getString(key)) |v| return v;
        if (self.parent) |p| if (p.getString(key)) |v| return v;
        return null;
    }

    fn getArray(self: BuildView, key: []const u8) ?[]const []const u8 {
        if (self.child) |c| if (c.getArray(key)) |v| return v;
        if (self.parent) |p| if (p.getArray(key)) |v| return v;
        return null;
    }
};

/// resolve `sources` (default `src/**/*.c`), and compile to `target`
/// (default `bin/<name>[.exe]`) via the embedded tcc.
fn projectBuild(arena: std.mem.Allocator, io: Io, cache: []const u8) !u8 {
    var stderr_buf: [1024]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &stderr_buf);

    const project_root = try findProjectRoot(io, arena);
    const toml_path = try std.fs.path.join(arena, &.{ project_root, "mc.toml" });
    if (!fmt_pkg.fileExists(io, toml_path)) {
        try stderr.interface.writeAll(
            "mc build: no mc.toml found in this directory or its parents\n" ++
                "Run `mc init` to scaffold one, or pass file(s) directly: mc build file.c -o out\n",
        );
        try stderr.interface.flush();
        return 1;
    }

    const toml_src = try Io.Dir.cwd().readFileAlloc(io, toml_path, arena, .unlimited);
    var doc = toml_pkg.parse(toml_src, arena) catch {
        try stderr.interface.writeAll("mc build: failed to parse mc.toml\n");
        try stderr.interface.flush();
        return 1;
    };
    defer doc.deinit();

    const build_sec = doc.section("build");
    const project_sec = doc.section("project");
    const name = if (project_sec) |p| p.getString("name") orelse "a" else "a";

    // build.outputs turns one mc.toml into N child builds ([build.<name>]
    // per entry), each inheriting shared keys (defines, include_dirs, ...)
    // from [build] but resolving sources/main/target from its own section
    // first. Without build.outputs, [build] itself is the single build.
    const outputs = if (build_sec) |b| b.getArray("outputs") else null;
    if (outputs) |names| {
        if (names.len == 0) {
            try stderr.interface.writeAll("mc build: build.outputs is empty in mc.toml\n");
            try stderr.interface.flush();
            return 1;
        }
        for (names) |out_name| {
            const child_name = try std.fmt.allocPrint(arena, "build.{s}", .{out_name});
            const view: BuildView = .{ .child = doc.section(child_name), .parent = build_sec };
            const rc = try buildOne(arena, io, cache, &stderr, project_root, view, out_name);
            if (rc != 0) return rc;
        }
        return 0;
    }

    const view: BuildView = .{ .child = build_sec, .parent = null };
    return try buildOne(arena, io, cache, &stderr, project_root, view, name);
}

/// Runs one resolve-sources/find-main/link-target build (either the sole
/// `[build]` in a project, or one `[build.<name>]` of a multi-output one).
/// `default_name` names the binary when `target` isn't set: the project
/// name for a single build, the output name for a multi-output one.
fn buildOne(
    arena: std.mem.Allocator,
    io: Io,
    cache: []const u8,
    stderr: anytype,
    project_root: []const u8,
    view: BuildView,
    default_name: []const u8,
) !u8 {
    var sources: std.ArrayList([]const u8) = .empty;
    if (view.getArray("sources")) |patterns| {
        for (patterns) |pat| try resolveSourcePattern(arena, io, project_root, pat, &sources);
    }
    if (sources.items.len == 0) {
        try defaultSources(arena, io, project_root, &sources);
    }

    if (sources.items.len == 0) {
        try stderr.interface.writeAll(
            "mc build: no source files found (checked build.sources in mc.toml, default src/**/*.c)\n",
        );
        try stderr.interface.flush();
        return 1;
    }

    // build.main is an explicit override for which file owns main() — skips
    // the auto-detection guard below entirely (convention over
    // configuration: the common case needs no [build] section at all, but
    // an ambiguous source tree can name the file that decides it).
    const explicit_main = view.getString("main");
    if (explicit_main) |m| {
        const full = try joinRelative(arena, project_root, m);
        var already = false;
        for (sources.items) |s| {
            if (std.mem.eql(u8, s, full)) {
                already = true;
                break;
            }
        }
        if (!already) try sources.append(arena, full);
    } else {
        // Multiple main()s across the resolved source set can't link into
        // one binary; point the user at build.sources/build.main rather
        // than letting tcc's linker error speak for itself.
        var main_files: std.ArrayList([]const u8) = .empty;
        for (sources.items) |s| {
            if (try countMainDefs(io, s, arena) > 0) try main_files.append(arena, s);
        }
        if (main_files.items.len > 1) {
            try stderr.interface.writeAll(
                "mc build: multiple files define main() - narrow build.sources or set build.main in mc.toml:\n",
            );
            for (main_files.items) |f| try stderr.interface.print("  {s}\n", .{f});
            try stderr.interface.flush();
            return 1;
        }
        if (main_files.items.len == 0) {
            try stderr.interface.writeAll("mc build: no file defines main() among resolved sources\n");
            try stderr.interface.flush();
            return 1;
        }
    }

    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const default_target = try std.fmt.allocPrint(arena, "bin/{s}{s}", .{ default_name, exe_suffix });
    const target_rel = view.getString("target") orelse default_target;
    const target_path = try joinRelative(arena, project_root, target_rel);

    if (std.fs.path.dirname(target_path)) |target_dir| {
        try Io.Dir.createDirPath(.cwd(), io, target_dir);
    }

    var tcc_argv: std.ArrayList([:0]const u8) = .empty;
    try tcc_argv.append(arena, try std.fmt.allocPrintSentinel(arena, "-B{s}", .{cache}, 0));

    if (view.getArray("include_dirs")) |dirs| {
        for (dirs) |d| {
            const full = try joinRelative(arena, project_root, d);
            try tcc_argv.append(arena, "-I");
            try tcc_argv.append(arena, try arena.dupeZ(u8, full));
        }
    }
    if (view.getArray("defines")) |defs| {
        for (defs) |d| try tcc_argv.append(arena, try std.fmt.allocPrintSentinel(arena, "-D{s}", .{d}, 0));
    }

    // lib_dirs (-L) is order-independent in tcc, so it's fine alongside -I/-D.
    // libs (-l) is emitted after sources below: tcc resolves undefined symbols
    // against -l archives in argv order, so it must come after the files that
    // reference them (GNU-ld convention). lib_dirs defaults to <root>/lib when
    // present, so a project that vendors a library there needs only `libs`.
    var lib_dirs = view.getArray("lib_dirs");
    var default_lib_dirs: [1][]const u8 = undefined;
    if (lib_dirs == null) {
        const default_dir = try std.fs.path.join(arena, &.{ project_root, "lib" });
        if (fmt_pkg.fileExists(io, default_dir)) {
            default_lib_dirs[0] = "lib";
            lib_dirs = default_lib_dirs[0..];
        }
    }
    if (lib_dirs) |dirs| {
        for (dirs) |d| {
            const full = try joinRelative(arena, project_root, d);
            // tcc does not normalize `..` in -L paths, so a consumer whose
            // lib_dir climbs out of its own tree (e.g. "../lib") would produce
            // an unresolved path and a "library not found" error. Resolve it to
            // a clean absolute path first.
            const resolved = try std.fs.path.resolve(arena, &.{full});
            try tcc_argv.append(arena, "-L");
            try tcc_argv.append(arena, try arena.dupeZ(u8, resolved));
        }
        // Executables do not search their own directory for shared libraries
        // they link, so a vendored shared lib shipped next to the binary
        // (e.g. in `bin/`) would fail to load at runtime. Add an rpath so
        // the loader looks beside the executable ($ORIGIN for ELF/Linux,
        // @executable_path for Mach-O/macOS; PE/Windows loads from exe dir).
        if (builtin.os.tag == .linux) {
            try tcc_argv.append(arena, "-Wl,-rpath,$ORIGIN");
        } else if (builtin.os.tag == .macos) {
            try tcc_argv.append(arena, "-Wl,-rpath,@executable_path");
        }
    }

    for (sources.items) |s| try tcc_argv.append(arena, try arena.dupeZ(u8, s));

    if (view.getArray("libs")) |libs| {
        for (libs) |l| try tcc_argv.append(arena, try std.fmt.allocPrintSentinel(arena, "-l{s}", .{l}, 0));
    }

    try tcc_argv.append(arena, "-o");
    try tcc_argv.append(arena, try arena.dupeZ(u8, target_path));

    var argv_buf = try arena.alloc([*c]u8, tcc_argv.items.len + 1);
    argv_buf[0] = @constCast("mc");
    for (tcc_argv.items, 1..) |arg, i| argv_buf[i] = @constCast(arg.ptr);
    const rc = tcc_main(@intCast(argv_buf.len), argv_buf.ptr);
    if (rc == 0) {
        var stdout_buf: [512]u8 = undefined;
        var stdout = Io.File.stdout().writer(io, &stdout_buf);
        try stdout.interface.print("Built {s}\n", .{target_rel});
        try stdout.interface.flush();
    }
    return @intCast(rc);
}

/// Recursively collect `*.c` files under `<project_root>/src` (fallback when
/// `mc.toml` sets no `build.sources`).
fn defaultSources(arena: std.mem.Allocator, io: Io, project_root: []const u8, out: *std.ArrayList([]const u8)) !void {
    const src_dir = try std.fs.path.join(arena, &.{ project_root, "src" });
    var dir = Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".c")) continue;
        try out.append(arena, try std.fs.path.join(arena, &.{ src_dir, entry.path }));
    }
}

/// Resolve one `build.sources` entry. Plain paths are used as-is; any
/// pattern containing `*` (`src/*.c`, `src/**/*.c`) walks the directory
/// portion before the first `*` recursively, keeping files with the
/// pattern's suffix (usually `.c`). This is not full glob syntax — it's
/// enough to let a project pick one platform-variant file over another by
/// listing it explicitly instead of a wildcard.
fn resolveSourcePattern(
    arena: std.mem.Allocator,
    io: Io,
    project_root: []const u8,
    pattern: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        try out.append(arena, try joinRelative(arena, project_root, pattern));
        return;
    };
    const dir_part = if (std.mem.lastIndexOfScalar(u8, pattern[0..star], '/')) |slash| pattern[0..slash] else ".";
    const suffix = if (std.mem.endsWith(u8, pattern, ".c")) ".c" else "";
    const full_dir = try joinRelative(arena, project_root, dir_part);

    var dir = Io.Dir.cwd().openDir(io, full_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (suffix.len > 0 and !std.mem.endsWith(u8, entry.basename, suffix)) continue;
        try out.append(arena, try std.fs.path.join(arena, &.{ full_dir, entry.path }));
    }
}

/// Cheap top-level `int main(`/`int main (` line scan — good enough to catch
/// the common "multiple mains in one source set" mistake without a real
/// C parser.
fn countMainDefs(io: Io, path: []const u8, arena: std.mem.Allocator) !usize {
    const content = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch return 0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "int main(") or std.mem.startsWith(u8, trimmed, "int main (")) {
            count += 1;
        }
    }
    return count;
}

fn cachePathFor(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    os_tag: std.Target.Os.Tag,
    arch_name: []const u8,
) ![]const u8 {
    if (env.get("MC_RUNTIME_CACHE_DIR")) |path| return path;

    const base = switch (os_tag) {
        .windows => env.get("LOCALAPPDATA") orelse return error.MissingCacheDirectory,
        .macos => try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.MissingCacheDirectory, "Library", "Caches" }),
        else => env.get("XDG_CACHE_HOME") orelse try std.fs.path.join(arena, &.{ env.get("HOME") orelse return error.MissingCacheDirectory, ".cache" }),
    };
    const target = try std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ tcc_version, arch_name, @tagName(os_tag) });
    return try std.fs.path.join(arena, &.{ base, "mc", target });
}

fn prepareRuntime(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) ![]const u8 {
    const cache = try cachePathFor(arena, env, builtin.os.tag, @tagName(builtin.cpu.arch));

    const marker = try std.fs.path.join(arena, &.{ cache, ".complete" });
    Io.Dir.access(.cwd(), io, marker, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try Io.Dir.createDirPath(.cwd(), io, cache);
            var dir = try Io.Dir.openDir(.cwd(), io, cache, .{});
            defer dir.close(io);
            var reader: Io.Reader = .fixed(runtime_archive);
            // ponytail: concurrent first runs may race; add a cache lock if this is observed in practice.
            try std.tar.extract(io, dir, &reader, .{});
            try dir.writeFile(io, .{ .sub_path = ".complete", .data = tcc_version });
        },
        else => return err,
    };
    return cache;
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
    _ = allocator;
    var buffer: [512]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);

    try Io.Dir.createDirPath(.cwd(), io, "src");

    if (!fmt_pkg.fileExists(io, "src/main.c")) {
        const main_file = try std.Io.Dir.cwd().createFile(io, "src/main.c", .{ .exclusive = true });
        defer main_file.close(io);
        var main_buf: [512]u8 = undefined;
        var mw = main_file.writer(io, &main_buf);
        try mw.interface.writeAll(
            \\#include <stdio.h>
            \\
            \\int main(void) {
            \\    printf("Hello World\n");
            \\    return 0;
            \\}
            \\
        );
        try mw.interface.flush();
        try stderr.interface.writeAll("Created src/main.c\n");
        try stderr.interface.flush();
    }

    const content =
        \\# mc.toml — generated by mc init
        \\
        \\[project]
        \\name    = "myproject"
        \\version = "0.1.0"
        \\
    ;

    const file = try std.Io.Dir.cwd().createFile(io, "mc.toml", .{ .exclusive = true });
    defer file.close(io);
    var file_buf: [512]u8 = undefined;
    var w = file.writer(io, &file_buf);
    try w.interface.writeAll(content);
    try w.interface.flush();

    try stderr.interface.writeAll("Created mc.toml\n");
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

    const shorthand = try route(arena, "/cache", &.{"hello.c"});
    try std.testing.expectEqualStrings("-B/cache", shorthand[0]);
    try std.testing.expectEqualStrings("-run", shorthand[1]);
    try std.testing.expectEqualStrings("hello.c", shorthand[2]);

    const build = try route(arena, "/cache", &.{ "build", "hello.c", "-o", "hello" });
    try std.testing.expectEqualStrings("-B/cache", build[0]);
    try std.testing.expectEqualStrings("hello.c", build[1]);
    try std.testing.expectEqualStrings("-o", build[2]);

    const run_args = try route(arena, "/cache", &.{ "run", "hello.c", "--", "one" });
    try std.testing.expectEqualStrings("-B/cache", run_args[0]);
    try std.testing.expectEqualStrings("-run", run_args[1]);
    try std.testing.expectEqualStrings("hello.c", run_args[2]);
    try std.testing.expectEqualStrings("one", run_args[3]);
}

test "route rejects run with no source file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.MissingSourceFile, route(arena, "/cache", &.{"run"}));
}

test "cachePathFor honors MC_RUNTIME_CACHE_DIR override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("MC_RUNTIME_CACHE_DIR", "/custom/cache");

    const path = try cachePathFor(arena, &env, .linux, "x86_64");
    try std.testing.expectEqualStrings("/custom/cache", path);
}

test "cachePathFor derives windows cache from LOCALAPPDATA" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local");

    const path = try cachePathFor(arena, &env, .windows, "x86_64");
    const target = try std.fmt.allocPrint(arena, "{s}-x86_64-windows", .{tcc_version});
    const expected = try std.fs.path.join(arena, &.{ "C:\\Users\\me\\AppData\\Local", "mc", target });
    try std.testing.expectEqualStrings(expected, path);
}

test "cachePathFor derives macos cache from HOME" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/Users/me");

    const path = try cachePathFor(arena, &env, .macos, "aarch64");
    const target = try std.fmt.allocPrint(arena, "{s}-aarch64-macos", .{tcc_version});
    const expected = try std.fs.path.join(arena, &.{ "/Users/me", "Library", "Caches", "mc", target });
    try std.testing.expectEqualStrings(expected, path);
}

test "cachePathFor uses XDG_CACHE_HOME over HOME on linux" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/me");
    try env.put("XDG_CACHE_HOME", "/home/me/.xdgcache");

    const path = try cachePathFor(arena, &env, .linux, "x86_64");
    const target = try std.fmt.allocPrint(arena, "{s}-x86_64-linux", .{tcc_version});
    const expected = try std.fs.path.join(arena, &.{ "/home/me/.xdgcache", "mc", target });
    try std.testing.expectEqualStrings(expected, path);
}

test "cachePathFor falls back to HOME/.cache on linux" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/me");

    const path = try cachePathFor(arena, &env, .linux, "x86_64");
    const target = try std.fmt.allocPrint(arena, "{s}-x86_64-linux", .{tcc_version});
    const expected = try std.fs.path.join(arena, &.{ "/home/me", ".cache", "mc", target });
    try std.testing.expectEqualStrings(expected, path);
}

test "cachePathFor errors without required env vars" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expectError(error.MissingCacheDirectory, cachePathFor(arena, &env, .windows, "x86_64"));
    try std.testing.expectError(error.MissingCacheDirectory, cachePathFor(arena, &env, .macos, "x86_64"));
    try std.testing.expectError(error.MissingCacheDirectory, cachePathFor(arena, &env, .linux, "x86_64"));
}
