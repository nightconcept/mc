//! Zig build system for mc toolchain packages.
//! Handles: zig build check (type-check all packages)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Vendored TOML module ─────────────────────────────────────────────────
    const toml_mod = b.createModule(.{
        .root_source_file = b.path("vendor/toml/toml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Package modules ──────────────────────────────────────────────────────
    const fmt_mod = b.createModule(.{
        .root_source_file = b.path("packages/fmt/format.zig"),
        .target = target,
        .optimize = optimize,
    });
    fmt_mod.addImport("toml", toml_mod);

    const lint_mod = b.createModule(.{
        .root_source_file = b.path("packages/lint/lint.zig"),
        .target = target,
        .optimize = optimize,
    });
    lint_mod.addImport("toml", toml_mod);
    lint_mod.addImport("fmt", fmt_mod);

    const lsp_mod = b.createModule(.{
        .root_source_file = b.path("packages/lsp/lsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    lsp_mod.addImport("toml", toml_mod);
    lsp_mod.addImport("fmt", fmt_mod);

    // ── zig build check ──────────────────────────────────────────────────────
    // Type-check all packages without emitting binaries.
    const check = b.step("check", "Type-check packages/fmt, lint, lsp, vendor/toml");

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
