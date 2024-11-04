// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Location = @import("Location.zig");
const Logger = @import("Logger.zig");

const BuildZigZon = @This();

name: []const u8,
version: std.SemanticVersion,
/// For deinitialization.
version_raw: []const u8,
/// Optional.
minimum_zig_version: ?std.SemanticVersion,
/// For deinitialization.
minimum_zig_version_raw: ?[]const u8,
/// Optional.
dependencies: ?std.json.ArrayHashMap(Dep),
paths: []const []const u8,

pub const Dep = struct {
    storage: Storage,
    lazy: ?bool,

    const Storage = union(enum) {
        local: struct {
            path: []const u8,
        },
        remote: struct {
            url: []const u8,
            hash: []const u8,
        },

        fn deinit(self: Storage, allocator: std.mem.Allocator) void {
            switch (self) {
                .local => |local| allocator.free(local.path),
                .remote => |remote| {
                    allocator.free(remote.url);
                    allocator.free(remote.hash);
                },
            }
        }
    };
};

pub fn deinit(self: *BuildZigZon, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    allocator.free(self.version_raw);
    if (self.minimum_zig_version_raw) |minimum_zig_version_raw|
        allocator.free(minimum_zig_version_raw);

    if (self.dependencies) |*dependencies| {
        for (dependencies.map.keys(), dependencies.map.values()) |key, value| {
            allocator.free(key);
            value.storage.deinit(allocator);
        }
        dependencies.deinit(allocator);
    }

    for (self.paths) |path| allocator.free(path);
    allocator.free(self.paths);
}

pub fn read(allocator: std.mem.Allocator, loc: Location.File, file_parsing_events: Logger) !BuildZigZon {
    const file_content = std.zig.readSourceFileToEndAlloc(allocator, loc.file, null) catch |err| {
        file_parsing_events.err(@src(), "Error when loading file: {s} caused by \"{s}\".", .{ @errorName(err), loc.string });
        return err;
    };
    defer allocator.free(file_content);

    var parser: Parser = try .init(allocator, file_content);
    defer parser.deinit();

    const build_zig_zon_struct = try parser.parse(file_parsing_events);
    return build_zig_zon_struct;
}

/// For specific file.
const Parser = struct {
    allocator: std.mem.Allocator,
    ast: std.zig.Ast,

    fn init(allocator: std.mem.Allocator, content: [:0]const u8) error{OutOfMemory}!Parser {
        return .{
            .allocator = allocator,
            .ast = try .parse(allocator, content, .zon),
        };
    }

    fn deinit(self: *Parser) void {
        self.ast.deinit(self.allocator);
    }

    fn parse(self: *Parser, file_parsing_events: Logger) error{ OutOfMemory, InvalidBuildZigZon }!BuildZigZon {
        const allocator = self.allocator;
        const ast = &self.ast;

        const root_node_index = ast.nodes.items(.data)[0].lhs;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, root_node_index) orelse {
            file_parsing_events.err(@src(), "Invalid struct", .{});
            return error.InvalidBuildZigZon;
        };

        file_parsing_events.debug(@src(), "Found {d} top-level fields, parsing...", .{struct_init.ast.fields.len});

        var result: BuildZigZon = .{
            .name = undefined,
            .version = undefined,
            .version_raw = undefined,
            .minimum_zig_version = null,
            .minimum_zig_version_raw = null,
            .dependencies = null,
            .paths = &.{},
        };

        const top_level_fields_parsing_events = try file_parsing_events.child("fields");
        defer top_level_fields_parsing_events.deinit();
        for (struct_init.ast.fields) |field_i| {
            const raw_field_name_i = ast.firstToken(field_i) - 2;
            const field_name = self.fieldName(raw_field_name_i) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.InvalidLiteral => {
                    top_level_fields_parsing_events.err(@src(), "Invalid field name: {s}", .{ast.tokenSlice(raw_field_name_i)});
                    return error.InvalidBuildZigZon;
                },
            };
            defer allocator.free(field_name);

            const field_parsing_events = try top_level_fields_parsing_events.child(field_name);
            defer field_parsing_events.deinit();

            const field_value = ast.tokenSlice(ast.nodes.items(.main_token)[field_i]);

            const TopLevelField = enum { name, version, minimum_zig_version, dependencies, paths, unknown };
            const top_level_field_type = std.meta.stringToEnum(TopLevelField, field_name) orelse .unknown;

            switch (top_level_field_type) {
                .name => {
                    result.name = self.stripQuotes(field_value) catch |err| {
                        switch (err) {
                            error.OutOfMemory => {},
                            error.InvalidBuildZigZon => {
                                field_parsing_events.err(@src(), "Invalid string: {s}", .{field_value});
                                return error.InvalidBuildZigZon;
                            },
                        }
                        return err;
                    };
                    field_parsing_events.debug(@src(), "Valid string: \"{s}\"", .{result.name});
                    continue;
                },
                inline .version, .minimum_zig_version => |tag| {
                    const version_string =
                        self.stripQuotes(field_value) catch |err| {
                        switch (err) {
                            error.OutOfMemory => {},
                            error.InvalidBuildZigZon => {
                                field_parsing_events.err(@src(), "Invalid string: {s}", .{field_value});
                                return error.InvalidBuildZigZon;
                            },
                        }
                        return err;
                    };
                    errdefer allocator.free(version_string);
                    @field(result, @tagName(tag) ++ "_raw") = version_string;

                    const sem_ver = std.SemanticVersion.parse(version_string) catch |err| {
                        field_parsing_events.err(@src(), "Invalid std.SemanticVersion: {s} because of {s}", .{ @errorName(err), version_string });
                        return error.InvalidBuildZigZon;
                    };

                    @field(result, @tagName(tag)) = sem_ver;
                    field_parsing_events.debug(@src(), "Valid std.SemanticVersion: {}", .{sem_ver});
                    continue;
                },
                .dependencies => {
                    var dep_buf: [2]std.zig.Ast.Node.Index = undefined;
                    const deps_init = ast.fullStructInit(&dep_buf, field_i) orelse {
                        field_parsing_events.err(@src(), "Invalid struct", .{});
                        return error.InvalidBuildZigZon;
                    };

                    field_parsing_events.debug(@src(), "Found {d} dependencies, parsing...", .{deps_init.ast.fields.len});

                    var deps: std.StringArrayHashMapUnmanaged(BuildZigZon.Dep) = .empty;
                    try deps.ensureTotalCapacity(allocator, deps_init.ast.fields.len);
                    for (deps_init.ast.fields) |dep_i| {
                        const raw_dep_name_i = ast.firstToken(dep_i) - 2;
                        const dep_name = self.fieldName(raw_dep_name_i) catch |err| switch (err) {
                            error.OutOfMemory => |e| return e,
                            error.InvalidLiteral => {
                                field_parsing_events.err(@src(), "Invalid dependency name: {s}", .{ast.tokenSlice(raw_dep_name_i)});
                                return error.InvalidBuildZigZon;
                            },
                        };

                        const dep_value_parsing_events = try field_parsing_events.child(dep_name);
                        defer dep_value_parsing_events.deinit();

                        var dep_field_buf: [2]std.zig.Ast.Node.Index = undefined;
                        const dep_value_init = ast.fullStructInit(&dep_field_buf, dep_i) orelse {
                            dep_value_parsing_events.err(@src(), "Invalid struct", .{});
                            return error.InvalidBuildZigZon;
                        };

                        var url: ?[]const u8 = null;
                        var hash: ?[]const u8 = null;
                        var path: ?[]const u8 = null;
                        var lazy: ?bool = null;
                        for (dep_value_init.ast.fields) |dep_field_i| {
                            const raw_dep_field_name_i = ast.firstToken(dep_field_i) - 2;
                            const dep_field_name = self.fieldName(raw_dep_field_name_i) catch |err| switch (err) {
                                error.OutOfMemory => |e| return e,
                                error.InvalidLiteral => {
                                    dep_value_parsing_events.err(@src(), "Invalid field name: {s}", .{ast.tokenSlice(raw_dep_name_i)});
                                    return error.InvalidBuildZigZon;
                                },
                            };
                            defer allocator.free(dep_field_name);

                            const dep_value_fields_parsing_events = try dep_value_parsing_events.child(dep_field_name);
                            defer dep_value_fields_parsing_events.deinit();

                            const dep_field_value = ast.tokenSlice(ast.nodes.items(.main_token)[dep_field_i]);

                            const DepField = enum { url, hash, path, lazy, unknown };
                            const dep_field_type = std.meta.stringToEnum(DepField, dep_field_name) orelse .unknown;

                            switch (dep_field_type) {
                                .url => {
                                    url = try self.stripQuotes(dep_field_value);
                                },
                                .hash => {
                                    hash = try self.stripQuotes(dep_field_value);
                                },
                                .path => {
                                    path = try self.stripQuotes(dep_field_value);
                                },
                                .lazy => {
                                    const lazy_value = std.meta.stringToEnum(enum { true, false }, dep_field_value) orelse {
                                        dep_value_fields_parsing_events.err(@src(), "Invalid boolean value: {s}", .{dep_field_value});
                                        return error.InvalidBuildZigZon;
                                    };
                                    switch (lazy_value) {
                                        .true => lazy = true,
                                        .false => lazy = false,
                                    }
                                },
                                .unknown => {
                                    dep_value_fields_parsing_events.warn(@src(), "Unknown type, skipping", .{});
                                    continue;
                                },
                            }
                        }

                        if (url != null and path != null) {
                            dep_value_parsing_events.err(@src(), "Can't have both \"url\" and \"path\" fields together", .{});
                            return error.InvalidBuildZigZon;
                        }

                        if (url != null and hash == null) {
                            dep_value_parsing_events.err(@src(), "Missing \"hash\" field for \"url\"-based dependency", .{});
                            return error.InvalidBuildZigZon;
                        }

                        if (path != null and hash != null) {
                            dep_value_parsing_events.err(@src(), "Can't have both \"path\" and \"hash\" fields together. Note: only \"url\"-based dependencies can have \"hash\"", .{});
                            return error.InvalidBuildZigZon;
                        }

                        const storage: BuildZigZon.Dep.Storage = if (url) |remote| remote: {
                            std.debug.assert(hash != null);
                            std.debug.assert(path == null);

                            // Normalize: '.url = "file://blabla"' to '.path = "blabla"'
                            const uri = std.Uri.parse(remote) catch |err| {
                                dep_value_parsing_events.err(@src(), "Invalid URI \"{s}\": {s}", .{ remote, @errorName(err) });
                                return error.InvalidBuildZigZon;
                            };
                            break :remote if (std.ascii.eqlIgnoreCase(uri.scheme, "file"))
                                .{ .local = .{ .path = try uri.path.toRawMaybeAlloc(allocator) } }
                            else
                                .{ .remote = .{ .url = remote, .hash = hash.? } };
                        } else if (path != null) local: {
                            std.debug.assert(url == null);
                            std.debug.assert(hash == null);
                            break :local .{ .local = .{ .path = path.? } };
                        } else {
                            dep_value_parsing_events.err(@src(), "Dependency has no \"url\" neither \"path\" field, unknown type of location", .{});
                            return error.InvalidBuildZigZon;
                        };

                        try deps.put(allocator, dep_name, .{
                            .lazy = lazy,
                            .storage = storage,
                        });
                    }

                    result.dependencies = .{ .map = deps };
                    continue;
                },
                .paths => {
                    var arr_buf: [2]std.zig.Ast.Node.Index = undefined;
                    const arr_init = ast.fullArrayInit(&arr_buf, field_i) orelse @panic("TODO: proper reporting (report to upstream of zig-ebuilder)");
                    var paths: std.ArrayListUnmanaged([]u8) = .empty;
                    try paths.ensureTotalCapacity(allocator, arr_init.ast.elements.len);
                    for (arr_init.ast.elements) |element_i| {
                        const element = try self.stripQuotes(ast.tokenSlice(ast.nodes.items(.main_token)[element_i]));
                        paths.appendAssumeCapacity(element);
                    }

                    result.paths = try paths.toOwnedSlice(allocator);
                    continue;
                },
                .unknown => {
                    field_parsing_events.warn(@src(), "Unknown type, skipping", .{});
                    continue;
                },
            }
        }

        return result;
    }

    /// note(BratishkaErik): Strictly speaking it does much more,
    /// including rendering escape sequences etc., but this name
    /// is easier to remember for me :(.
    fn stripQuotes(self: Parser, raw_string: []const u8) error{ OutOfMemory, InvalidBuildZigZon }![]u8 {
        if (raw_string.len < 2 or raw_string[0] != '"' or raw_string[raw_string.len - 1] != '"') {
            // scoped.log("String is not inside of double quoutes ("_"): [raw_string]")
            return error.InvalidBuildZigZon;
        }

        const result = std.zig.string_literal.parseAlloc(self.allocator, raw_string) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => {
                //scoped.log("String is invalid literal: [raw_string]");
                return error.InvalidBuildZigZon;
            },
        };
        return result;
    }

    fn fieldName(self: Parser, token: std.zig.Ast.TokenIndex) error{ OutOfMemory, InvalidLiteral }![]u8 {
        const token_tags = self.ast.tokens.items(.tag);
        std.debug.assert(token_tags[token] == .identifier);

        const ident_name = self.ast.tokenSlice(token);
        return if (std.mem.startsWith(u8, ident_name, "@"))
            stripQuotes(self, ident_name[1..]) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.InvalidBuildZigZon => return error.InvalidLiteral,
            }
        else
            try self.allocator.dupe(u8, ident_name);
    }
};
