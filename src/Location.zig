// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Location = @This();

pub const Dir = struct {
    string: []const u8,
    dir: std.fs.Dir,

    pub fn openFile(self: Location.Dir, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.File.OpenError)!Location.File {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const file = try self.dir.openFile(path, .{});
        return .{ .string = string, .file = file };
    }

    pub fn openDir(self: Location.Dir, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.Dir.OpenError)!Location.Dir {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const dir = try self.dir.openDir(path, .{});
        return .{ .string = string, .dir = dir };
    }

    pub fn makeOpenDir(self: Location.Dir, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.Dir.MakeError || std.fs.Dir.OpenError || std.fs.Dir.StatFileError)!Location.Dir {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const dir = try self.dir.makeOpenPath(path, .{});
        return .{ .string = string, .dir = dir };
    }

    pub fn deinit(self: *Location.Dir, allocator: std.mem.Allocator) void {
        allocator.free(self.string);
        self.dir.close();
    }
};

pub const File = struct {
    string: []const u8,
    file: std.fs.File,

    pub fn openFile(self: Location.File, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.File.OpenError)!Location.Dir {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const dir = try self.dir.openDir(path, .{});
        return .{ .string = string, .dir = dir };
    }

    pub fn deinit(self: Location.File, allocator: std.mem.Allocator) void {
        allocator.free(self.string);
        self.file.close();
    }
};
