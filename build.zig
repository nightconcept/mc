//! Zig build system for mc toolchain packages.
//! Handles: zig build check (type-check all packages)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Package modules ──────────────────────────────────────────────────────
    const external_toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const external_toml_mod = external_toml_dep.module("toml");

    const toml_mod = b.createModule(.{
        .root_source_file = b.path("src/toml/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    toml_mod.addImport("toml", external_toml_mod);

    const fmt_mod = b.createModule(.{
        .root_source_file = b.path("src/fmt/format.zig"),
        .target = target,
        .optimize = optimize,
    });
    fmt_mod.addImport("toml", toml_mod);

    const lint_mod = b.createModule(.{
        .root_source_file = b.path("src/lint/lint.zig"),
        .target = target,
        .optimize = optimize,
    });
    lint_mod.addImport("fmt", fmt_mod);
    lint_mod.addImport("toml", toml_mod);

    const lsp_mod = b.createModule(.{
        .root_source_file = b.path("src/lsp/lsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_mod.addImport("fmt", fmt_mod);
    lsp_mod.addImport("toml", toml_mod);

    // ── zig build check ──────────────────────────────────────────────────────
    // Type-check all packages without emitting binaries.
    const check = b.step("check", "Type-check src/fmt, lint, lsp");

    const modules = [_]struct {
        name: []const u8,
        mod: *std.Build.Module,
    }{
        .{ .name = "fmt", .mod = fmt_mod },
        .{ .name = "lint", .mod = lint_mod },
        .{ .name = "lsp", .mod = lsp_mod },
    };

    for (modules) |m| {
        const obj = b.addObject(.{
            .name = m.name,
            .root_module = m.mod,
        });
        check.dependOn(&obj.step);
    }
}
