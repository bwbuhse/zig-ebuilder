// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const BuildZigZon = @import("BuildZigZon.zig");
const Dependencies = @import("Dependencies.zig");
const Location = @import("Location.zig");
const Logger = @import("Logger.zig");

const ZigProcess = @This();

/// Zig executable to use.
exe: []const u8,
env_map: *const std.process.EnvMap,

pub fn version(
    self: ZigProcess,
    cwd: Location.Dir,
    allocator: std.mem.Allocator,
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
    cwd: Location.Dir,
    allocator: std.mem.Allocator,
    storage_dir: []const u8,
    resource: BuildZigZon.Dep,
    fetch_mode: Dependencies.FetchMode,
    file_events: Logger,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self.exe,
        "fetch",
        "--global-cache-dir",
        storage_dir,
        switch (resource.storage) {
            .remote => |remote| remote.url,
            .local => |local| local.path,
        },
    });
    switch (fetch_mode) {
        .hashed => switch (resource.storage) {
            .remote => |remote| try argv.append(allocator, remote.hash),
            .local => {},
        },
        .plain => {},
        .skip => @panic("unreachable"),
    }

    file_events.debug(@src(), "Running command: cd \"{!s}\" && {s}", .{ cwd.string, argv.items });
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
    cwd: Location.Dir,
    allocator: std.mem.Allocator,
    build_zig_path: []const u8,
    build_runner_path: []const u8,
    packages_loc: Location.Dir,
    additional_args: [][:0]const u8,
    file_events: Logger,
) std.process.Child.RunError!std.process.Child.RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        self.exe,
        "build",
        "--build-file",
        build_zig_path,
        "--build-runner",
        build_runner_path,
        "--system",
        packages_loc.string,
        // TODO is it truly needed? sorting JSON values works for now
        // "--seed",
        // "1",
    });
    try argv.appendSlice(allocator, additional_args);

    file_events.debug(@src(), "Running command: cd \"{!s}\" && {s}", .{ cwd.string, argv.items });
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd_dir = cwd.dir,
        .env_map = self.env_map,
        .max_output_bytes = 1 * 1024 * 1024,
    });
}
