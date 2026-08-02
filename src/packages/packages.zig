//! URL-sourced package manifests, locks, Git cache, and source graphs.

const std = @import("std");
const builtin = @import("builtin");
const toml = @import("toml");

pub const ProjectKind = enum { application, package };

pub const Error = error{
    InvalidProjectKind,
    InvalidPackageManifest,
    InvalidDependencyUrl,
    UnsafePath,
    MissingLockfile,
    MissingLockEntry,
    InvalidLockfile,
    LockIntegrityMismatch,
    DependencyCycle,
    PackageDefinesMain,
    GitFailed,
};

pub const LockEntry = struct {
    url: []const u8,
    revision: []const u8,
    tree_hash: []const u8,
};

pub const ResolvedGraph = struct {
    sources: []const []const u8,
    include_dirs: []const []const u8,

    pub fn deinit(self: ResolvedGraph, allocator: std.mem.Allocator) void {
        for (self.sources) |path| allocator.free(path);
        if (self.sources.len != 0) allocator.free(self.sources);
        for (self.include_dirs) |path| allocator.free(path);
        if (self.include_dirs.len != 0) allocator.free(self.include_dirs);
    }
};

/// Reads the intentionally small public distinction in an mc.toml manifest.
/// Existing manifests remain applications when `project.kind` is omitted.
pub fn projectKind(doc: *const toml.Document) Error!ProjectKind {
    const project = doc.section("project") orelse return .application;
    const value = project.getString("kind") orelse return .application;
    if (std.mem.eql(u8, value, "application")) return .application;
    if (std.mem.eql(u8, value, "package")) return .package;
    return error.InvalidProjectKind;
}

pub fn dependencies(doc: *const toml.Document) []const []const u8 {
    const root = doc.root() orelse return &.{};
    return root.getArray("dependencies") orelse &.{};
}

pub fn validateUrl(url: []const u8) Error!void {
    if (url.len == 0 or std.mem.indexOfAny(u8, url, " \t\r\n\\\"") != null) return error.InvalidDependencyUrl;
    const base = urlBase(url);
    if (std.mem.startsWith(u8, base, "https://") or
        std.mem.startsWith(u8, base, "ssh://") or std.mem.startsWith(u8, base, "file://") or
        std.mem.startsWith(u8, base, "git@")) return;
    return error.InvalidDependencyUrl;
}

pub fn initPackage(io: std.Io, allocator: std.mem.Allocator, repository: []const u8) !void {
    try validateUrl(repository);
    const name = try packageName(allocator, repository);
    try std.Io.Dir.createDirPath(.cwd(), io, "src");
    const include = try std.fs.path.join(allocator, &.{ "include", name });
    try std.Io.Dir.createDirPath(.cwd(), io, include);
    const content = try std.fmt.allocPrint(allocator, "[project]\nname = \"{s}\"\nversion = \"0.1.0\"\nkind = \"package\"\nrepository = \"{s}\"\n\n[package]\nsources = [\"src/**/*.c\"]\ninclude_dirs = [\"include\"]\n", .{ name, repository });
    try writeNew(io, "mc.toml", content);
}

/// Resolve only the revisions recorded in `mc.lock`. Missing checkouts are
/// fetched at the locked revision; a build never asks a remote for a newer ref.
pub fn resolveLockedGraph(
    io: std.Io,
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    project_root: []const u8,
    strict: bool,
) !ResolvedGraph {
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "mc.toml" });
    const manifest_src = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    var manifest = try toml.parse(manifest_src, allocator);
    defer manifest.deinit();
    const declared = dependencies(&manifest);
    if (declared.len == 0) return .{ .sources = &.{}, .include_dirs = &.{} };

    const lock_path = try std.fs.path.join(allocator, &.{ project_root, "mc.lock" });
    const lock_src = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .unlimited) catch return error.MissingLockfile;
    const locks = try parseLock(allocator, lock_src);
    defer freeLockEntries(allocator, locks);
    const cache_root = try packageCachePath(allocator, env);

    var sources: std.ArrayList([]const u8) = .empty;
    var includes: std.ArrayList([]const u8) = .empty;
    var visiting: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (declared) |url| {
        try resolveOne(io, allocator, cache_root, locks, url, &visiting, &seen, &sources, &includes);
    }
    if (strict and (seen.count() != locks.len or !allLockEntriesSeen(locks, &seen))) return error.MissingLockEntry;
    return .{ .sources = try sources.toOwnedSlice(allocator), .include_dirs = try includes.toOwnedSlice(allocator) };
}

/// Resolve every direct and transitive URL, then write a stable project lock.
pub fn update(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, project_root: []const u8, selected: []const []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "mc.toml" });
    const manifest_src = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    var manifest = try toml.parse(manifest_src, allocator);
    defer manifest.deinit();
    const declared = dependencies(&manifest);
    for (selected) |url| if (!contains(declared, url)) return error.InvalidDependencyUrl;

    var entries: std.ArrayList(LockEntry) = .empty;
    var visiting: std.StringHashMapUnmanaged(void) = .empty;
    const cache_root = try packageCachePath(allocator, env);
    if (selected.len > 0) {
        const lock_path = try std.fs.path.join(allocator, &.{ project_root, "mc.lock" });
        const old_src = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .unlimited) catch return error.MissingLockfile;
        const old_entries = try parseLock(allocator, old_src);
        for (old_entries) |entry| if (!contains(selected, entry.url)) try entries.append(allocator, entry);
        for (selected) |url| try updateOne(io, allocator, cache_root, url, &visiting, &entries);
    } else {
        for (declared) |url| try updateOne(io, allocator, cache_root, url, &visiting, &entries);
    }
    sortEntries(entries.items);
    const lock = try formatLock(allocator, entries.items);
    const lock_path = try std.fs.path.join(allocator, &.{ project_root, "mc.lock" });
    try writeAtomic(io, allocator, lock_path, lock);
}

/// Add an exact URL to the root dependency array, resolve it, and regenerate
/// the lock. The writer deliberately owns only the root `dependencies` line.
pub fn add(io: std.Io, allocator: std.mem.Allocator, env: *const std.process.Environ.Map, project_root: []const u8, url: []const u8) !void {
    try validateUrl(url);
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "mc.toml" });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    var doc = try toml.parse(source, allocator);
    defer doc.deinit();
    if (contains(dependencies(&doc), url)) return update(io, allocator, env, project_root, &.{});

    const rewritten = try rewriteDependencies(allocator, source, dependencies(&doc), url);
    // Fetch before mutating the manifest. If acquisition fails, the project is unchanged.
    const scratch_path = try std.fs.path.join(allocator, &.{ project_root, ".mc.add.toml" });
    try writeAtomic(io, allocator, scratch_path, rewritten);
    defer std.Io.Dir.cwd().deleteFile(io, scratch_path) catch {};
    const cache_root = try packageCachePath(allocator, env);
    var entries: std.ArrayList(LockEntry) = .empty;
    var visiting: std.StringHashMapUnmanaged(void) = .empty;
    for (dependencies(&doc)) |dep| try updateOne(io, allocator, cache_root, dep, &visiting, &entries);
    try updateOne(io, allocator, cache_root, url, &visiting, &entries);
    sortEntries(entries.items);
    const lock = try formatLock(allocator, entries.items);
    try writeAtomic(io, allocator, manifest_path, rewritten);
    const lock_path = try std.fs.path.join(allocator, &.{ project_root, "mc.lock" });
    try writeAtomic(io, allocator, lock_path, lock);
}

fn resolveOne(io: std.Io, allocator: std.mem.Allocator, cache_root: []const u8, locks: []const LockEntry, url: []const u8, visiting: *std.ArrayList([]const u8), seen: *std.StringHashMapUnmanaged(void), sources: *std.ArrayList([]const u8), includes: *std.ArrayList([]const u8)) !void {
    if (seen.contains(url)) return;
    if (contains(visiting.items, url)) return error.DependencyCycle;
    const entry = findLock(locks, url) orelse return error.MissingLockEntry;
    const checkout = try ensureCheckout(io, allocator, cache_root, entry.url, entry.revision);
    const hash = try archiveHash(io, allocator, checkout, entry.revision);
    if (!std.mem.eql(u8, hash, entry.tree_hash)) return error.LockIntegrityMismatch;
    try visiting.append(allocator, url);
    defer _ = visiting.pop();
    const src = try std.fs.path.join(allocator, &.{ checkout, "mc.toml" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .unlimited);
    var doc = try toml.parse(text, allocator);
    defer doc.deinit();
    try validatePackageManifest(&doc);
    for (dependencies(&doc)) |child| try resolveOne(io, allocator, cache_root, locks, child, visiting, seen, sources, includes);
    try appendPackageFiles(io, allocator, checkout, &doc, sources, includes);
    try seen.put(allocator, url, {});
}

fn updateOne(io: std.Io, allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8, visiting: *std.StringHashMapUnmanaged(void), entries: *std.ArrayList(LockEntry)) !void {
    if (findLock(entries.items, url) != null) return;
    if (visiting.contains(url)) return error.DependencyCycle;
    try validateUrl(url);
    try visiting.put(allocator, url, {});
    defer _ = visiting.remove(url);
    const revision = try resolveRevision(io, allocator, url);
    const checkout = try ensureCheckout(io, allocator, cache_root, url, revision);
    const tree_hash = try archiveHash(io, allocator, checkout, revision);
    try entries.append(allocator, .{ .url = try allocator.dupe(u8, url), .revision = revision, .tree_hash = tree_hash });
    const src = try std.fs.path.join(allocator, &.{ checkout, "mc.toml" });
    const text = try std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .unlimited);
    var doc = try toml.parse(text, allocator);
    defer doc.deinit();
    try validatePackageManifest(&doc);
    for (dependencies(&doc)) |child| try updateOne(io, allocator, cache_root, child, visiting, entries);
}

fn appendPackageFiles(io: std.Io, allocator: std.mem.Allocator, root: []const u8, doc: *const toml.Document, sources: *std.ArrayList([]const u8), includes: *std.ArrayList([]const u8)) !void {
    try validatePackageManifest(doc);
    const package = doc.section("package").?;
    const default_patterns = [_][]const u8{"src/**/*.c"};
    const patterns = package.getArray("sources") orelse default_patterns[0..];
    for (patterns) |pattern| try expandSourcePattern(io, allocator, root, pattern, sources);
    const default_dirs = [_][]const u8{"include"};
    const dirs = package.getArray("include_dirs") orelse default_dirs[0..];
    for (dirs) |dir| {
        try validateRelative(dir);
        const full = try joinRelative(allocator, root, dir);
        if (fileExists(io, full)) try includes.append(allocator, full);
    }
    for (sources.items) |source| if (try countMainDefs(io, allocator, source) != 0) return error.PackageDefinesMain;
}

fn validatePackageManifest(doc: *const toml.Document) !void {
    if (try projectKind(doc) != .package) return error.InvalidPackageManifest;
    const package = doc.section("package") orelse return error.InvalidPackageManifest;
    if (package.getArray("sources")) |patterns| for (patterns) |pattern| try validateRelative(pattern);
    if (package.getArray("include_dirs")) |dirs| for (dirs) |dir| try validateRelative(dir);
}

fn resolveRevision(io: std.Io, allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const base = urlBase(url);
    const ref = urlRef(url) orelse "HEAD";
    const output = try gitOutput(io, allocator, &.{ "ls-remote", base, ref });
    var first: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (first == null) first = line[0..tab];
        if (std.mem.endsWith(u8, line[tab + 1 ..], "^{}")) return allocator.dupe(u8, line[0..tab]);
    }
    return allocator.dupe(u8, first orelse return error.GitFailed);
}

fn ensureCheckout(io: std.Io, allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8, revision: []const u8) ![]const u8 {
    const key = try cacheKey(allocator, url, revision);
    const final = try std.fs.path.join(allocator, &.{ cache_root, key });
    const marker = try std.fs.path.join(allocator, &.{ final, ".mc-complete" });
    if (std.Io.Dir.cwd().readFileAlloc(io, marker, allocator, .limited(128))) |recorded| {
        if (std.mem.eql(u8, recorded, revision)) return final;
        return error.LockIntegrityMismatch;
    } else |_| {}
    try std.Io.Dir.createDirPath(.cwd(), io, cache_root);
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ final, processId() });
    std.Io.Dir.cwd().deleteTree(io, temp) catch {};
    try gitStatus(io, allocator, &.{ "clone", "--no-checkout", urlBase(url), temp });
    try gitStatus(io, allocator, &.{ "-C", temp, "checkout", "--detach", revision });
    var dir = try std.Io.Dir.cwd().openDir(io, temp, .{});
    try dir.writeFile(io, .{ .sub_path = ".mc-complete", .data = revision });
    dir.close(io);
    std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), final, io) catch |err| {
        if (!fileExists(io, marker)) return err;
        std.Io.Dir.cwd().deleteTree(io, temp) catch {};
    };
    return final;
}

fn processId() u32 {
    return if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.c.getpid());
}

fn archiveHash(io: std.Io, allocator: std.mem.Allocator, checkout: []const u8, revision: []const u8) ![]const u8 {
    const bytes = try gitOutput(io, allocator, &.{ "-C", checkout, "archive", "--format=tar", revision });
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
}

fn gitOutput(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "git");
    try argv.appendSlice(allocator, args);
    var child = std.process.spawn(io, .{ .argv = argv.items, .stdout = .pipe, .stderr = .pipe }) catch return error.GitFailed;
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = child.stdout.?.reader(io, &out_buf);
    var err = child.stderr.?.reader(io, &err_buf);
    const bytes = out.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024)) catch return error.GitFailed;
    defer allocator.free(err.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch &.{});
    const term = child.wait(io) catch return error.GitFailed;
    return switch (term) {
        .exited => |code| if (code == 0) bytes else error.GitFailed,
        else => error.GitFailed,
    };
}

fn gitStatus(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const bytes = gitOutput(io, allocator, args) catch return error.GitFailed;
    allocator.free(bytes);
}

fn packageCachePath(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("MC_PACKAGE_CACHE_DIR")) |path| return allocator.dupe(u8, path);
    const base = switch (@import("builtin").os.tag) {
        .windows => env.get("LOCALAPPDATA") orelse return error.InvalidPackageManifest,
        .macos => try std.fs.path.join(allocator, &.{ env.get("HOME") orelse return error.InvalidPackageManifest, "Library", "Caches" }),
        else => env.get("XDG_CACHE_HOME") orelse try std.fs.path.join(allocator, &.{ env.get("HOME") orelse return error.InvalidPackageManifest, ".cache" }),
    };
    return std.fs.path.join(allocator, &.{ base, "mc", "packages" });
}

fn parseLock(allocator: std.mem.Allocator, source: []const u8) ![]const LockEntry {
    var entries: std.ArrayList(LockEntry) = .empty;
    var current: ?LockEntry = null;
    var version_ok = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.eql(u8, line, "version = 1")) {
            version_ok = true;
            continue;
        }
        if (std.mem.eql(u8, line, "[[dependency]]")) {
            if (current) |entry| try entries.append(allocator, entry);
            current = .{ .url = "", .revision = "", .tree_hash = "" };
            continue;
        }
        if (current) |*entry| {
            if (valueFor(line, "url")) |v| entry.url = try allocator.dupe(u8, v) else if (valueFor(line, "revision")) |v| entry.revision = try allocator.dupe(u8, v) else if (valueFor(line, "tree_hash")) |v| entry.tree_hash = try allocator.dupe(u8, v);
        }
    }
    if (current) |entry| try entries.append(allocator, entry);
    if (!version_ok) return error.InvalidLockfile;
    for (entries.items) |entry| {
        try validateUrl(entry.url);
        if (entry.revision.len < 7 or !std.mem.startsWith(u8, entry.tree_hash, "sha256:")) return error.InvalidLockfile;
    }
    return entries.toOwnedSlice(allocator);
}

fn freeLockEntries(allocator: std.mem.Allocator, entries: []const LockEntry) void {
    for (entries) |entry| {
        allocator.free(entry.url);
        allocator.free(entry.revision);
        allocator.free(entry.tree_hash);
    }
    allocator.free(entries);
}

fn formatLock(allocator: std.mem.Allocator, entries: []const LockEntry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "version = 1\n");
    for (entries) |entry| {
        try out.appendSlice(allocator, "\n[[dependency]]\n");
        const record = try std.fmt.allocPrint(allocator, "url = \"{s}\"\nrevision = \"{s}\"\ntree_hash = \"{s}\"\n", .{ entry.url, entry.revision, entry.tree_hash });
        try out.appendSlice(allocator, record);
    }
    return out.toOwnedSlice(allocator);
}

fn rewriteDependencies(allocator: std.mem.Allocator, source: []const u8, old: []const []const u8, new: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "dependencies = [");
    for (old) |url| {
        const item = try std.fmt.allocPrint(allocator, "\n  \"{s}\",", .{url});
        try out.appendSlice(allocator, item);
    }
    const last = try std.fmt.allocPrint(allocator, "\n  \"{s}\",\n]\n\n", .{new});
    try out.appendSlice(allocator, last);
    // Root assignments must precede sections. Remove precisely the existing
    // array expression, including a multiline array, without reformatting
    // the user's sections and comments.
    if (dependencyRange(source)) |range| {
        try out.appendSlice(allocator, source[0..range.start]);
        try out.appendSlice(allocator, source[range.end..]);
    } else try out.appendSlice(allocator, source);
    return out.toOwnedSlice(allocator);
}

fn dependencyRange(source: []const u8) ?struct { start: usize, end: usize } {
    const start = std.mem.indexOf(u8, source, "dependencies") orelse return null;
    const eq = std.mem.indexOfScalarPos(u8, source, start, '=') orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, eq, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, source, open, ']') orelse return null;
    const line_start = std.mem.lastIndexOfScalar(u8, source[0..start], '\n') orelse 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, close, '\n') orelse source.len;
    return .{ .start = if (line_start == 0) 0 else line_start + 1, .end = if (line_end < source.len) line_end + 1 else line_end };
}

fn writeNew(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn writeAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    const file = try std.Io.Dir.cwd().createFile(io, temp, .{});
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
    file.close(io);
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
}

fn packageName(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const base = std.mem.trim(u8, urlBase(url), "/");
    const raw = std.fs.path.basename(base);
    const name = if (std.mem.endsWith(u8, raw, ".git")) raw[0 .. raw.len - 4] else raw;
    if (name.len == 0) return error.InvalidDependencyUrl;
    return allocator.dupe(u8, name);
}

fn urlBase(url: []const u8) []const u8 {
    return url[0..(std.mem.indexOfScalar(u8, url, '#') orelse url.len)];
}
fn urlRef(url: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, url, '#') orelse return null;
    return if (start + 1 < url.len) url[start + 1 ..] else null;
}
fn findLock(entries: []const LockEntry, url: []const u8) ?LockEntry {
    for (entries) |entry| if (std.mem.eql(u8, entry.url, url)) return entry;
    return null;
}
fn allLockEntriesSeen(entries: []const LockEntry, seen: *const std.StringHashMapUnmanaged(void)) bool {
    for (entries) |entry| if (!seen.contains(entry.url)) return false;
    return true;
}
fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}
fn sortEntries(entries: []LockEntry) void {
    std.mem.sort(LockEntry, entries, {}, struct {
        fn lessThan(_: void, a: LockEntry, b: LockEntry) bool {
            return std.mem.lessThan(u8, a.url, b.url);
        }
    }.lessThan);
}
fn valueFor(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len < key.len + 5 or !std.mem.eql(u8, line[key.len .. key.len + 4], " = \"")) return null;
    const start = key.len + 4;
    if (line.len < start + 1 or line[line.len - 1] != '\"') return null;
    return line[start .. line.len - 1];
}
fn cacheKey(allocator: std.mem.Allocator, url: []const u8, revision: []const u8) ![]const u8 {
    const input = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ url, revision });
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
}
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
fn validateRelative(path: []const u8) Error!void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.UnsafePath;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.UnsafePath;
}
fn joinRelative(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ![]const u8 {
    try validateRelative(relative);
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(allocator, root);
    var it = std.mem.tokenizeAny(u8, relative, "/\\");
    while (it.next()) |part| try parts.append(allocator, part);
    return std.fs.path.join(allocator, parts.items);
}
fn expandSourcePattern(io: std.Io, allocator: std.mem.Allocator, root: []const u8, pattern: []const u8, out: *std.ArrayList([]const u8)) !void {
    try validateRelative(pattern);
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        try out.append(allocator, try joinRelative(allocator, root, pattern));
        return;
    };
    const prefix = if (std.mem.lastIndexOfScalar(u8, pattern[0..star], '/')) |i| pattern[0..i] else ".";
    const dir_path = try joinRelative(allocator, root, prefix);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".c")) try out.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.path }));
}
fn countMainDefs(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !usize {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trim = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trim, "int main(") or std.mem.startsWith(u8, trim, "int main (")) count += 1;
    }
    return count;
}

test "project kind defaults to application" {
    var doc = try toml.parse("[project]\nname = \"app\"\n", std.testing.allocator);
    defer doc.deinit();
    try std.testing.expectEqual(.application, try projectKind(&doc));
}
test "package url accepts GitHub Forgejo and file remotes" {
    try validateUrl("https://github.com/acme/json");
    try validateUrl("https://forge.example/acme/json#v1");
    try validateUrl("file:///tmp/json");
    try std.testing.expectError(error.InvalidDependencyUrl, validateUrl("../json"));
}
test "lock parser requires immutable fields" {
    const lock = "version = 1\n\n[[dependency]]\nurl = \"https://github.com/acme/json\"\nrevision = \"abcdef0\"\ntree_hash = \"sha256:123\"\n";
    const entries = try parseLock(std.testing.allocator, lock);
    defer freeLockEntries(std.testing.allocator, entries);
    try std.testing.expectEqualStrings("abcdef0", entries[0].revision);
}
