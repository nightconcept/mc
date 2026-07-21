const std = @import("std");
const Io = std.Io;

extern fn c2m_main(argc: c_int, argv: [*c][*c]u8, envp: [*c][*c]u8) c_int;

const usage =
    \\mc (Modern C) -- MIR/c2mir-backed C compiler
    \\Usage:
    \\  mc file.c [args]            Compile and run (JIT via c2mir -eg)
    \\  mc run file.c -- [args]     Compile and run
    \\  mc build [c2m arguments]    Build an artifact (-c/-S/-o, ...)
    \\  mc lint file.c              Compile, checking syntax only
    \\  mc c2m [c2m arguments]      Use the original c2mir interface
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
    } else if (eql(args[0], "lint")) {
        try out.appendSlice(arena, &.{"-fsyntax-only"});
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

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "routes commands" {
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
