// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Location = @import("Location.zig");
const Logger = @import("Logger.zig");

const setup = @This();

pub const Generator = struct {
    /// Absolute.
    cache: Location.Dir,
    /// Absolute.
    dependencies_storage: Location.Dir,
    /// Absolute.
    packages: Location.Dir,

    pub fn deinit(self: *setup.Generator, allocator: std.mem.Allocator) void {
        self.packages.deinit(allocator);
        self.dependencies_storage.deinit(allocator);
        self.cache.deinit(allocator);
    }

    pub fn makeOpen(
        cwd: Location.Dir,
        env_map: std.process.EnvMap,
        allocator: std.mem.Allocator,
        events: Logger,
    ) (error{ OutOfMemory, CacheNotFound } ||
        std.fs.Dir.MakeError ||
        std.fs.Dir.OpenError ||
        std.fs.File.OpenError)!setup.Generator {
        const cache_path = cache_path: {
            if (env_map.get("XDG_CACHE_HOME")) |xdg_cache_home| xdg: {
                // Pre spec, ${XDG_CACHE_HOME} must be set and non empty.
                // And also be an absolute path.
                if (xdg_cache_home.len == 0) {
                    events.err(@src(), "XDG_CACHE_HOME is set but content is empty, ignoring.", .{});
                    break :xdg;
                } else if (!std.fs.path.isAbsolute(xdg_cache_home)) {
                    events.err(@src(), "XDG_CACHE_HOME is set but content is not an absolute path, ignoring.", .{});
                    break :xdg;
                }

                break :cache_path try std.fs.path.join(allocator, &.{ xdg_cache_home, "zig-ebuilder" });
            }

            const home = env_map.get("HOME") orelse {
                events.err(@src(), "Neither XDG_CACHE_HOME nor HOME is set, aborting.", .{});
                return error.CacheNotFound;
            };
            if (home.len == 0) {
                events.err(@src(), "XDG_CACHE_HOME is not set, HOME is set but content empty, aborting.", .{});
                return error.CacheNotFound;
            } else if (!std.fs.path.isAbsolute(home)) {
                events.err(@src(), "XDG_CACHE_HOME is not set, HOME is set but content is not an absolute path, aborting.", .{});
                return error.CacheNotFound;
            }
            break :cache_path try std.fs.path.join(allocator, &.{ home, ".cache", "zig-ebuilder" });
        };
        defer allocator.free(cache_path);
        std.debug.assert(std.fs.path.isAbsolute(cache_path));

        const paths = .{
            .cache = cache_path,
            .dependencies_storage = "deps",
            .packages = "p",
        };
        events.debug(@src(), "paths = {}", .{std.json.fmt(paths, .{ .whitespace = .indent_2 })});

        events.info(@src(), "Opening cache directory \"{s}\"...", .{cache_path});

        var cache = cwd.makeOpenDir(allocator, paths.cache) catch |err| {
            events.err(@src(), "Error when creating directory \"{s}\": {s}. Aborting.", .{ paths.cache, @errorName(err) });
            return err;
        };
        errdefer cache.deinit(allocator);

        var dependencies_storage = cache.makeOpenDir(allocator, paths.dependencies_storage) catch |err| {
            events.err(@src(), "Error when creating directory \"{s}\": {s}. Aborting.", .{ paths.dependencies_storage, @errorName(err) });
            return err;
        };
        errdefer dependencies_storage.deinit(allocator);

        var packages = dependencies_storage.makeOpenDir(allocator, paths.packages) catch |err| {
            events.err(@src(), "Error when creating directory \"{s}\": {s}. Aborting.", .{ paths.packages, @errorName(err) });
            return err;
        };
        errdefer packages.deinit(allocator);

        return .{
            .cache = cache,
            .dependencies_storage = dependencies_storage,
            .packages = packages,
        };
    }
};

pub const Project = struct {
    /// Relative to `cwd`.
    root: Location.Dir,

    /// Relative to `root`.
    build_zig: Location.File,
    /// Relative to `root`.
    build_zig_zon: ?Location.File,

    pub fn deinit(self: *setup.Project, allocator: std.mem.Allocator) void {
        if (self.build_zig_zon) |build_zig_zon| build_zig_zon.deinit(allocator);
        self.build_zig.deinit(allocator);
        self.root.deinit(allocator);
    }

    pub fn open(
        cwd: Location.Dir,
        initial_build_zig_path: []const u8,
        allocator: std.mem.Allocator,
        events: Logger,
    ) (error{OutOfMemory} || std.fs.Dir.OpenError || std.fs.File.OpenError)!setup.Project {
        const paths = .{
            .root = std.fs.path.dirname(initial_build_zig_path) orelse ".",
            .build_zig = std.fs.path.basename(initial_build_zig_path),
            .build_zig_zon = "build.zig.zon",
        };
        events.debug(@src(), "paths = {}", .{std.json.fmt(paths, .{ .whitespace = .indent_2 })});

        var root = cwd.openDir(allocator, paths.root) catch |err| {
            events.err(@src(), "Error when opening project \"{s}\": {s}. Aborting.", .{ paths.root, @errorName(err) });
            return err;
        };
        errdefer root.deinit(allocator);

        const build_zig_path_relative_to_root = try allocator.dupe(u8, paths.build_zig);
        errdefer allocator.free(build_zig_path_relative_to_root);

        const build_zig: Location.File = .{
            .string = build_zig_path_relative_to_root,
            .file = root.dir.openFile(build_zig_path_relative_to_root, .{}) catch |err| {
                events.err(@src(), "Error when opening file \"{s}\": {s}. Aborting.", .{ build_zig_path_relative_to_root, @errorName(err) });
                return err;
            },
        };
        errdefer build_zig.file.close();

        const build_zig_zon_path_relative_to_root = try allocator.dupe(u8, paths.build_zig_zon);
        errdefer allocator.free(build_zig_zon_path_relative_to_root);

        const build_zig_zon: Location.File = .{
            .string = build_zig_zon_path_relative_to_root,
            .file = root.dir.openFile(build_zig_zon_path_relative_to_root, .{}) catch |err| {
                events.err(@src(), "Error when opening file \"{s}\": {s}. Ignoring.", .{ build_zig_zon_path_relative_to_root, @errorName(err) });
                allocator.free(build_zig_zon_path_relative_to_root);
                return .{
                    .root = root,
                    .build_zig = build_zig,
                    .build_zig_zon = null,
                };
            },
        };
        errdefer build_zig_zon.file.close();

        return .{
            .root = root,
            .build_zig = build_zig,
            .build_zig_zon = build_zig_zon,
        };
    }
};
