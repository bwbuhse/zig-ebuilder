// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const BuildZigZon = @import("BuildZigZon.zig");
const Dependencies = @import("Dependencies.zig");
const Logger = @import("Logger.zig");

const location = @import("location.zig");
const setup = @import("setup.zig");

const ZigProcess = @This();

/// Zig executable to use.
exe: []const u8,
env_map: *const std.process.EnvMap,

pub fn version(
    self: ZigProcess,
    allocator: std.mem.Allocator,
    cwd: location.Dir,
) std.process.Child.RunError!std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            self.exe,
            "version",
        },
        .cwd_dir = cwd.dir,
        .env_map = self.env_map,
        .max_output_bytes = 1024,
    });
}

pub fn fetch(
    self: ZigProcess,
    allocator: std.mem.Allocator,
    cwd: location.Dir,
    args: struct {
        storage_loc: location.Dir,
        resource: BuildZigZon.Dep,
        fetch_mode: Dependencies.FetchMode,
    },
    events: Logger,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self.exe,
        "fetch",
        "--global-cache-dir",
        args.storage_loc.string,
        switch (args.resource.storage) {
            .remote => |remote| remote.url,
            .local => |local| local.path,
        },
    });
    switch (args.fetch_mode) {
        .hashed => switch (args.resource.storage) {
            .remote => |remote| try argv.append(allocator, remote.hash),
            .local => {},
        },
        .plain => {},
        .skip => @panic("unreachable"),
    }

    events.debug(@src(), "Running command: cd \"{!s}\" && {s}", .{ cwd.string, argv.items });
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd_dir = cwd.dir,
        .env_map = self.env_map,
        .max_output_bytes = 1 * 1024,
    });
}

pub fn build(
    self: ZigProcess,
    allocator: std.mem.Allocator,
    project_setup: setup.Project,
    args: struct {
        build_runner_path: []const u8,
        packages_loc: location.Dir,
        additional: [][:0]const u8,
    },
    events: Logger,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self.exe,
        "build",
        "--build-file",
        project_setup.build_zig.string,
        "--build-runner",
        args.build_runner_path,
        "--system",
        args.packages_loc.string,
        // TODO is it truly needed? sorting JSON values works for now
        // "--seed",
        // "1",
    });
    try argv.appendSlice(allocator, args.additional);

    events.debug(@src(), "Running command: cd \"{!s}\" && {s}", .{ project_setup.root.string, argv.items });
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd_dir = project_setup.root.dir,
        .env_map = self.env_map,
        .max_output_bytes = 1 * 1024 * 1024,
    });
}
