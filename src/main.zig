// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");
const mustache = @import("mustache");

const BuildZigZon = @import("BuildZigZon.zig");
const Dependencies = @import("Dependencies.zig");
const Location = @import("Location.zig");
const Logger = @import("Logger.zig");
const Report = @import("reports/Report.zig");
const Timestamp = @import("Timestamp.zig");
const ZigProcess = @import("ZigProcess.zig");

const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 1 };

fn printHelp(writer: std.io.AnyWriter) void {
    writer.print(
        \\Usage: {[prog_name]s} [flags] <path>
        \\
        \\Flags:
        \\    --help                             Print this help
        \\
        \\    --zig=[path]                       Specify Zig executable to use
        \\    --color=[on|off|auto]              Whether to use color in logs
        \\    --time=[none|time|day_time]        Whether to print "time" or "day and time" in logs
        \\    --src_loc=[on|off]                 Whether to print source location in logs
        \\    --min_level=[err|warn|info|debug]  Severity of printed logs
        \\
        \\    --zig_build_additional_args [...]  Additional args to pass for "zig build" verbatim
        \\    --fetch=[skip|plain|hashed]        Choose method for fetching: none, plain, or hashed (requires patch)
        \\    --custom_template=[path]           Specify custom Mustache template to use for generating ebuild
        \\
        \\ <path> should be a build.zig file, or directory containing it;
        \\ if none is provided, defaults to current working directory.
        \\
        \\ If it has a build.zig.zon file nearby, `zig-ebuilder` will fetch all dependencies eagerly
        \\ and recursively, and fill ZBS_DEPENDENCIES array. If such file does not exist, array will be empty.
        \\
        \\ Arguments for "zig build" may be useful if you want to enable some option that will link
        \\ system library and so show it in report by generator, if it's required to pass etc.
        \\
        \\ Fetch methods: "skip" is none, "plain" is regular `zig fetch`, "hashed" is `zig fetch` with patch
        \\ https://github.com/ziglang/zig/pull/21589 . By default it is "plain" for all Zig versions.
        \\
        \\ **Warning**: if you want to make fetching fast by using "--fetch=hashed",
        \\ please patch your dev-lang/zig:9999 using /etc/portage/patches/ and link above
        \\ and put it there. This will make fetching instantenous if you have already\
        \\ fetched dependencies previously, otherwise "zig fetch" would initiate
        \\ connections to verify content. More details in that PR.
        \\
    , .{ .prog_name = global.prog_name }) catch {};
}

var global: struct {
    prog_name: [:0]const u8,
    zig_executable: [:0]const u8,
    fetch_mode: Dependencies.FetchMode,
} = .{
    .prog_name = "(name not provided)",
    .zig_executable = "zig",
    .fetch_mode = .plain,
};

pub fn main() !void {
    var gpa_instance: std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .enable_memory_limit = true,
        .thread_safe = true,
    }) = .init;
    defer switch (gpa_instance.deinit()) {
        .ok => {},
        .leak => @panic("Memory leak detected!"),
    };
    const gpa = gpa_instance.allocator();

    var env_map = try std.process.getEnvMap(gpa);
    defer env_map.deinit();
    // For consistent output of "reuse lint" and "reuse spdx"
    try env_map.put("LC_ALL", "en_US.UTF-8");

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    if (args.next()) |name| global.prog_name = name;

    const stdout_file = std.io.getStdOut();
    const stderr_file = std.io.getStdErr();
    const stdout = stdout_file.writer().any();
    const stderr = stderr_file.writer().any();

    stderr.print("Starting {s} {}\n", .{ global.prog_name, version }) catch {};

    var zig_build_additional_args: [][:0]const u8 = &.{};
    defer gpa.free(zig_build_additional_args);

    var optional_custom_template_path: ?[:0]const u8 = null;
    var file_name: ?[:0]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(stdout);
            return;
        } else if (std.mem.startsWith(u8, arg, "--zig=")) {
            const text = arg["--zig=".len..];
            global.zig_executable = if (text.len != 0) text else {
                stderr.print("Expected non-empty path to \"zig\" binary\n", .{}) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--color=")) {
            const text = arg["--color=".len..];
            Logger.global_format.color = std.meta.stringToEnum(@FieldType(Logger.Format, "color"), text) orelse {
                stderr.print("Expected [on|off|auto] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--time=")) {
            const text = arg["--time=".len..];
            Logger.global_format.time = std.meta.stringToEnum(@FieldType(Logger.Format, "time"), text) orelse {
                stderr.print("Expected [none|time|day_time] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--src_loc=")) {
            const text = arg["--src_loc=".len..];
            Logger.global_format.src_loc = std.meta.stringToEnum(@FieldType(Logger.Format, "src_loc"), text) orelse {
                stderr.print("Expected [on|off] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--min_level=")) {
            const text = arg["--min_level=".len..];
            Logger.global_format.min_level = std.meta.stringToEnum(@FieldType(Logger.Format, "min_level"), text) orelse {
                stderr.print("Expected [err|warn|info|debug] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.eql(u8, arg, "--zig_build_additional_args")) {
            var additional_args: std.ArrayListUnmanaged([:0]const u8) = .empty;
            errdefer additional_args.deinit(gpa);
            while (args.next()) |zig_build_arg| {
                try additional_args.append(gpa, zig_build_arg);
            }
            if (additional_args.items.len == 0) {
                stderr.print("Expected following args after \"{s}\"\n", .{arg}) catch {};
                return;
            }
            zig_build_additional_args = try additional_args.toOwnedSlice(gpa);
        } else if (std.mem.startsWith(u8, arg, "--fetch=")) {
            const text = arg["--fetch=".len..];
            global.fetch_mode = std.meta.stringToEnum(Dependencies.FetchMode, text) orelse {
                stderr.print("Expected [skip|plain|hashed] in \"{s}\", found \"{s}\"\n", .{ arg, text }) catch {};
                return;
            };
        } else if (std.mem.startsWith(u8, arg, "--custom_template=")) {
            const text = arg["--custom_template=".len..];
            optional_custom_template_path = if (text.len != 0) text else {
                stderr.print("Expected non-empty path to custom template\n", .{}) catch {};
                return;
            };
        } else {
            if (file_name) |previous_path| {
                stderr.print("More than 1 path at same time specified: \"{s}\" and \"{s}\".", .{ previous_path, arg }) catch {};
                stderr.writeAll("If you wanted to pass option, please make sure that '=' symbols are reproduced exactly as written in \"--help\".\n") catch {};
                return;
            }
            file_name = arg;
        }
    }

    var main_log: Logger = .{
        .shared = &.{ .scretch_pad = gpa },
        .scopes = &.{},
    };
    var file_events = try main_log.child("file");
    defer file_events.deinit();
    var file_searching_events = try file_events.child("searching");
    defer file_searching_events.deinit();

    const cwd = std.fs.cwd();

    const template_text = if (optional_custom_template_path) |custom_template_path|
        cwd.readFileAlloc(gpa, custom_template_path, 1 * 1024 * 1024) catch |err| {
            file_searching_events.err(@src(), "Error when searching custom template: {s} caused by \"{s}\".", .{ @errorName(err), custom_template_path });

            return error.InvalidTemplate;
        }
    else
        // TODO maybe move to /usr/share/stuff/templates/default ?
        try gpa.dupe(u8, @embedFile("template.ebuild.mustache"));
    defer gpa.free(template_text);

    const template = switch (try mustache.parseText(gpa, template_text, .{}, .{ .copy_strings = false })) {
        .parse_error => |detail| {
            file_searching_events.err(@src(), "Error when loading file: {s} caused by \"{s}\" at {d}:{d}.", .{
                @errorName(detail.parse_error),
                if (optional_custom_template_path) |custom_template_path| custom_template_path else "(default template)",
                detail.lin,
                detail.col,
            });
            return error.InvalidTemplate;
        },
        .success => |template| template,
    };
    defer template.deinit(gpa);

    const initial_file_path: []const u8 = if (file_name) |path| blk: {
        const stat = cwd.statFile(path) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    file_searching_events.err(@src(), "File or directory \"{s}\" not found.", .{path});
                },
                else => |e| {
                    file_searching_events.err(@src(), "Error when checking type of \"{s}\": {s}.", .{ path, @errorName(e) });
                },
            }
            return err;
        };

        switch (stat.kind) {
            .file => {
                file_searching_events.info(@src(), "\"{s}\" is a file, trying to open it...", .{path});
                break :blk try gpa.dupe(u8, path);
            },
            .directory => {
                file_searching_events.info(@src(), "\"{s}\" is a directory, trying to find \"build.zig\" file inside...", .{path});
                break :blk try std.fs.path.join(gpa, &.{ path, "build.zig" });
            },
            .sym_link => {
                file_searching_events.err(@src(), "Can't resolve symlink \"{s}\".", .{path});
                return error.FileNotFound;
            },
            //
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => |tag| {
                file_searching_events.err(@src(), "\"{s}\" is not a file or directory, but instead it's \"{s}\".", .{ path, @tagName(tag) });
                return error.FileNotFound;
            },
        }
    } else cwd: {
        file_searching_events.info(@src(), "No location given, trying to open \"build.zig\" in current directory...", .{});
        break :cwd try gpa.dupe(u8, "build.zig");
    };
    defer gpa.free(initial_file_path);

    const dir_path = std.fs.path.dirname(initial_file_path) orelse ".";
    const build_zig_path = std.fs.path.basename(initial_file_path);
    const build_zig_zon_path = try std.mem.concat(gpa, u8, &.{ build_zig_path, ".zon" }); //&.{ initial_file_path, ".zon" });
    defer gpa.free(build_zig_zon_path);

    main_log.debug(@src(), "initial_dir_path = {s}", .{dir_path});
    main_log.debug(@src(), "build_zig_path = {s}", .{build_zig_path});
    main_log.debug(@src(), "build_zig_zon_path = {s}", .{build_zig_zon_path});

    var project_dir = cwd.openDir(dir_path, .{}) catch |err| {
        file_searching_events.err(@src(), "Error when opening project \"{s}\": {s}.", .{ dir_path, @errorName(err) });
        return err;
    };
    defer project_dir.close();
    const project_loc: Location.Dir = .{ .dir = project_dir, .string = dir_path };

    const build_zig = project_dir.openFile(build_zig_path, .{}) catch |err| {
        file_searching_events.err(@src(), "Error when opening file \"{s}\": {s}.", .{ initial_file_path, @errorName(err) });
        return err;
    };
    defer build_zig.close();
    file_searching_events.info(@src(), "Successfully found \"build.zig\" file!", .{});

    const zig_process: ZigProcess = .{
        .exe = global.zig_executable,
        .env_map = &env_map,
    };

    const zig_version_raw_string = zig_version_raw_string: {
        const result_of_zig_version = try zig_process.version(project_loc, gpa);
        defer {
            gpa.free(result_of_zig_version.stderr);
            gpa.free(result_of_zig_version.stdout);
        }

        if (result_of_zig_version.stderr.len != 0) {
            main_log.err(@src(), "Error when checking Zig version: {s}", .{result_of_zig_version.stderr});
            return;
        }

        const version_to_parse = std.mem.trim(u8, result_of_zig_version.stdout, &std.ascii.whitespace);
        break :zig_version_raw_string try gpa.dupe(u8, version_to_parse);
    };
    defer gpa.free(zig_version_raw_string);
    const zig_version = std.SemanticVersion.parse(zig_version_raw_string) catch |err| switch (err) {
        error.InvalidVersion, error.Overflow => {
            main_log.err(@src(), "Error when parsing Zig version: {s} caused by {s}.", .{ @errorName(err), zig_version_raw_string });
            return;
        },
    };
    main_log.info(@src(), "Found Zig version {any}, processing...", .{zig_version});
    std.debug.assert(zig_version.major == 0);

    // Minimal Zig version supported by zig-ebuild.eclass
    const minimum_supported_zig_version: std.SemanticVersion = .{ .major = 0, .minor = 13, .patch = 0 };
    if (zig_version.order(minimum_supported_zig_version) == .lt) {
        main_log.err(@src(), "Zig version is not supported by \"zig-ebuild.eclass\": {any} is less than {any}", .{ minimum_supported_zig_version, zig_version });
        return;
    }

    const zig_slot: ZigSlot = try .init(zig_version, gpa);
    defer zig_slot.deinit(gpa);
    main_log.info(@src(), "ZIG_SLOT is set to {s}", .{zig_slot.render()});

    const cache_path = cache_path: {
        if (env_map.get("XDG_CACHE_HOME")) |xdg_cache_home| xdg: {
            // Pre spec, ${XDG_CACHE_HOME} must be set and non empty.
            // And also be an absolute path.
            if (xdg_cache_home.len == 0) {
                main_log.err(@src(), "XDG_CACHE_HOME is set but content is empty, ignoring.", .{});
                break :xdg;
            } else if (!std.fs.path.isAbsolute(xdg_cache_home)) {
                main_log.err(@src(), "XDG_CACHE_HOME is set but content is not an absolute path, ignoring.", .{});
                break :xdg;
            }

            break :cache_path try std.fs.path.join(gpa, &.{ xdg_cache_home, "zig-ebuilder" });
        }

        const home = env_map.get("HOME") orelse {
            main_log.err(@src(), "Neither XDG_CACHE_HOME nor HOME is set, aborting.", .{});
            return;
        };
        if (home.len == 0) {
            main_log.err(@src(), "XDG_CACHE_HOME is not set, HOME is set but content empty, aborting.", .{});
            return;
        } else if (!std.fs.path.isAbsolute(home)) {
            main_log.err(@src(), "XDG_CACHE_HOME is not set, HOME is set but content is not an absolute path, aborting.", .{});
            return;
        }
        break :cache_path try std.fs.path.join(gpa, &.{ home, ".cache", "zig-ebuilder" });
    };
    defer gpa.free(cache_path);
    main_log.info(@src(), "Opening cache directory \"{s}\"...", .{cache_path});
    std.debug.assert(std.fs.path.isAbsolute(cache_path));

    var cache_dir = try cwd.makeOpenPath(cache_path, .{});
    defer cache_dir.close();
    var cache_loc: Location.Dir = .{ .dir = cache_dir, .string = cache_path };

    var dependencies_loc = try cache_loc.makeOpenDir(gpa, "deps");
    defer dependencies_loc.deinit(gpa);

    var packages_loc = try dependencies_loc.makeOpenDir(gpa, "p");
    defer packages_loc.deinit(gpa);

    const dependencies: Dependencies = if (global.fetch_mode != .skip) fetch: {
        const build_zig_zon = project_dir.openFile(build_zig_zon_path, .{}) catch |err| {
            file_searching_events.err(@src(), "Error when opening file \"{s}.zon\": {s}. Skipping fetching.", .{ initial_file_path, @errorName(err) });
            break :fetch .empty;
        };
        defer build_zig_zon.close();
        file_searching_events.info(@src(), "Found \"build.zig.zon\" file nearby, proceeding to fetch dependencies.", .{});

        const project_build_zig_zon_location: Location.File = .{ .file = build_zig_zon, .string = initial_file_path };

        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        const project_build_zig_zon: BuildZigZon = try .read(arena, project_build_zig_zon_location, file_events);
        break :fetch try .collect(
            gpa,
            arena,
            //
            project_build_zig_zon,
            project_loc,
            dependencies_loc,
            packages_loc,
            file_events,
            global.fetch_mode,
            zig_process,
        );
    } else .empty;
    defer dependencies.deinit(gpa);

    const optional_tarball_tarball_path: ?[]const u8 = if (dependencies.git_commit.len != 0) tarball_tarball: {
        file_events.warn(@src(), "Found dependencies that were not translated from Git commit to tarball format: {d} items. Packing them into one archive...", .{dependencies.git_commit.len});
        var tarballs_loc = try cache_loc.makeOpenDir(gpa, "git_commit_tarballs");
        defer tarballs_loc.deinit(gpa);

        var tar_mem: std.ArrayListUnmanaged(u8) = .empty;
        defer tar_mem.deinit(gpa);

        var hashed_writer = std.compress.hashedWriter(tar_mem.writer(gpa), std.hash.Crc32.init());
        try Dependencies.createGitCommitDependenciesTarball(gpa, dependencies.git_commit, packages_loc, hashed_writer.writer());

        // Used for generated tarball-tarball name.
        const project_name = dependencies.root_package_name;

        const tarball_tarball_path = try std.fmt.allocPrint(gpa, "{s}-{d}.tar.gz", .{ project_name, hashed_writer.hasher.final() });
        defer gpa.free(tarball_tarball_path);

        try tarballs_loc.dir.writeFile(.{
            .sub_path = tarball_tarball_path,
            .data = tar_mem.items,
        });

        break :tarball_tarball try std.fs.path.join(gpa, &.{ tarballs_loc.string, tarball_tarball_path });
    } else null;
    defer if (optional_tarball_tarball_path) |tarball_tarball_path| gpa.free(tarball_tarball_path);

    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    main_log.info(@src(), "Running \"zig build\" with custom build runner. Arguments are in DEBUG.", .{});
    const report: Report = try .collect(
        gpa,
        //
        &env_map,
        cache_loc,
        build_zig_path,
        packages_loc,
        main_log,
        zig_build_additional_args,
        project_loc,
        zig_slot,
        zig_process,
        arena,
    );

    const context = .{
        .generator_version = try std.fmt.allocPrint(gpa, "{}", .{version}),
        .year = year: {
            const time: Timestamp = .now();
            break :year time.year;
        },
        .zbs = .{
            .slot = zig_slot.render(),
            .has_dependencies = @max(dependencies.tarball.len, dependencies.git_commit.len) > 0,
            .has_system_dependencies = @max(report.system_integrations.len, report.system_libraries.len) > 0,
            .has_user_options = report.user_options.len > 0,
            .dependencies = dependencies,
            .tarball_tarball = optional_tarball_tarball_path,
            .report = report,
        },
    };
    defer gpa.free(context.generator_version);

    main_log.info(@src(), "Writing generated ebuild to STDOUT...", .{});
    try mustache.render(template, context, stdout);
    main_log.info(@src(), "Generated ebuild was written to STDOUT.", .{});
    main_log.info(@src(), "Note (if using default template): license header there (with \"Gentoo Authors\" and GNU GPLv2) is just an convenience default for making ebuilds for ::gentoo and ::guru repos easier, you can relicense output however you want.", .{});

    if (optional_tarball_tarball_path) |tarball_tarball_path| {
        main_log.warn(@src(), "Note: it appears your project has Git commit dependencies that generator was unable to convert, please host \"{s}\" somewhere and add it to SRC_URI.", .{tarball_tarball_path});
    }
}

pub const ZigSlot = union(enum) {
    live,
    release: []const u8,

    pub fn render(self: ZigSlot) []const u8 {
        return switch (self) {
            .live => "9999",
            .release => |release| release,
        };
    }

    pub fn init(zig_version: std.SemanticVersion, allocator: std.mem.Allocator) error{OutOfMemory}!ZigSlot {
        return if (zig_version.pre == null) .{
            .release = try std.fmt.allocPrint(allocator, "{d}.{d}", .{ zig_version.major, zig_version.minor }),
        } else .live;
    }

    pub fn deinit(self: ZigSlot, allocator: std.mem.Allocator) void {
        switch (self) {
            .live => {},
            .release => |release| allocator.free(release),
        }
    }
};
