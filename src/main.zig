// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");
const mustache = @import("mustache");

const Logger = @import("Logger.zig");
const Timestamp = @import("Timestamp.zig");

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
    fetch_mode: FetchMode,
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
            global.fetch_mode = std.meta.stringToEnum(FetchMode, text) orelse {
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
    const build_zig = project_dir.openFile(build_zig_path, .{}) catch |err| {
        file_searching_events.err(@src(), "Error when opening file \"{s}\": {s}.", .{ initial_file_path, @errorName(err) });
        return err;
    };
    defer build_zig.close();
    file_searching_events.info(@src(), "Successfully found \"build.zig\" file!", .{});

    const zig_version_raw_string = zig_version_raw_string: {
        const result_of_zig_version = try std.process.Child.run(.{
            .allocator = gpa,
            .argv = &.{
                global.zig_executable,
                "version",
            },
            .cwd_dir = project_dir,
            .env_map = &env_map,
            .max_output_bytes = 1024,
        });
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

    const zig_slot: union(enum) {
        live,
        release: []const u8,

        fn render(self: @This()) []const u8 {
            return switch (self) {
                .live => "9999",
                .release => |release| release,
            };
        }
    } = if (zig_version.pre == null) .{ .release = try std.fmt.allocPrint(gpa, "{d}.{d}", .{ zig_version.major, zig_version.minor }) } else .live;
    defer switch (zig_slot) {
        .live => {},
        .release => |release| gpa.free(release),
    };

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
    var cache_loc: DirLocation = .{ .dir = cache_dir, .string = cache_path };

    var dependencies_loc = try cache_loc.makeOpenDir(gpa, "deps");
    defer dependencies_loc.deinit(gpa);

    var packages_loc = try dependencies_loc.makeOpenDir(gpa, "p");
    defer packages_loc.deinit(gpa);

    var optional_project_name: ?[]const u8 = null;
    defer if (optional_project_name) |project_name| gpa.free(project_name);
    const dependencies: Dependencies = if (project_dir.openFile(build_zig_zon_path, .{})) |build_zig_zon| fetch: {
        defer build_zig_zon.close();
        file_searching_events.info(@src(), "Found \"build.zig.zon\" file nearby, proceeding to fetch dependencies.", .{});

        const project_loc: DirLocation = .{ .dir = project_dir, .string = dir_path };
        const project_build_zig_zon_location: FileLocation = .{ .file = build_zig_zon, .string = initial_file_path };

        var arena_instance: std.heap.ArenaAllocator = .init(gpa);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();

        const project_build_zig_zon = try readBuildZigZon(arena, project_build_zig_zon_location, file_events);
        optional_project_name = try gpa.dupe(u8, project_build_zig_zon.name);
        break :fetch try generateDependenciesArray(
            gpa,
            arena,
            //
            project_build_zig_zon,
            project_loc,
            dependencies_loc,
            packages_loc,
            file_events,
            &env_map,
        );
    } else |err| no_fetch: {
        file_searching_events.warn(@src(), "Error when opening file \"{s}.zon\": {s}. Skipping fetching.", .{ initial_file_path, @errorName(err) });
        break :no_fetch .{ .tarball = &.{}, .git_commit = &.{} };
    };
    defer dependencies.deinit(gpa);

    var optional_tarball_tarball_path: ?[]const u8 = null;
    defer if (optional_tarball_tarball_path) |tarball_tarball_path| gpa.free(tarball_tarball_path);
    if (dependencies.git_commit.len != 0) {
        main_log.warn(@src(), "Found dependencies that were not translated from Git commit to tarball format: {d} items. Packing them into one archive...", .{dependencies.git_commit.len});
        var tarballs_loc = try cache_loc.makeOpenDir(gpa, "git_commit_tarballs");
        defer tarballs_loc.deinit(gpa);

        var tar_mem: std.ArrayListUnmanaged(u8) = .empty;
        defer tar_mem.deinit(gpa);

        var hashed_writer = std.compress.hashedWriter(tar_mem.writer(gpa), std.hash.Crc32.init());
        try createGitCommitDependenciesTarball(gpa, dependencies.git_commit, packages_loc, hashed_writer.writer());

        const tarball_tarball_path = try std.fmt.allocPrint(gpa, "{s}-{d}.tar.gz", .{ optional_project_name orelse "no_name", hashed_writer.hasher.final() });
        defer gpa.free(tarball_tarball_path);

        try tarballs_loc.dir.writeFile(.{
            .sub_path = tarball_tarball_path,
            .data = tar_mem.items,
        });

        optional_tarball_tarball_path = try std.fs.path.join(gpa, &.{ tarballs_loc.string, tarball_tarball_path });
    }

    const build_runner_map: std.StaticStringMap([:0]const u8) = .initComptime(.{
        .{ "0.13", @embedFile("build_runner_0.13.zig") },
        .{ "9999", @embedFile("build_runner_9999.zig") },
    });
    const build_runner_text = build_runner_map.get(zig_slot.render()) orelse {
        main_log.err(@src(), "No build runner found for Zig {s}, please report to zig-ebuilder upstream.", .{zig_slot.render()});
        main_log.err(@src(), "Expected to find: {s}, but only these are available: {s}.", .{ zig_slot.render(), build_runner_map.keys() });
        return;
    };

    const hashed_name = hashed_name: {
        const hash_suffix = std.Build.Cache.HashHelper.oneShot(build_runner_text);
        break :hashed_name try std.fmt.allocPrint(gpa, "build_runner_{s}_{s}.zig", .{ zig_slot.render(), hash_suffix });
    };
    defer gpa.free(hashed_name);

    var build_runners_loc = try cache_loc.makeOpenDir(gpa, "build_runners");
    defer build_runners_loc.deinit(gpa);
    try build_runners_loc.dir.writeFile(.{
        .sub_path = hashed_name,
        .data = build_runner_text,
        .flags = .{ .read = true, .truncate = true },
    });

    const build_runner_path = try std.fs.path.join(gpa, &.{ build_runners_loc.string, hashed_name });
    defer gpa.free(build_runner_path);

    const report_address: std.net.Address = .initIp6(@as([15]u8, @splat(0)) ++ .{1}, 0, 0, 0);
    var report_server = try report_address.listen(.{});
    defer report_server.deinit();
    main_log.info(@src(), "Report server address: {}", .{report_server.listen_address});

    try env_map.putMove(
        try gpa.dupe(u8, "ZIG_EBUILDER_REPORT_LISTEN_PORT"),
        try std.fmt.allocPrint(gpa, "{d}", .{report_server.listen_address.getPort()}),
    );

    // Locked by default, unlocked by `receiveReport` thread
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var output: FullReport = .{ .lock = .{}, .report = undefined };
    const thread = try std.Thread.spawn(.{ .stack_size = 16 * 1024 }, receiveReport, .{ arena, &report_server, &output });
    thread.detach();

    const runner_args = runner_args: {
        var zig_build_args: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer zig_build_args.deinit(gpa);

        try zig_build_args.appendSlice(gpa, &.{
            global.zig_executable,
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
        try zig_build_args.appendSlice(gpa, zig_build_additional_args);
        break :runner_args try zig_build_args.toOwnedSlice(gpa);
    };
    defer gpa.free(runner_args);

    main_log.info(@src(), "Running \"zig build\" with custom build runner. Arguments are in DEBUG.", .{});
    main_log.debug(@src(), "Running command: {s}", .{runner_args});

    // Blocks thread
    const result_of_zig_build_runner = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = runner_args,
        .cwd_dir = project_dir,
        .env_map = &env_map,
        .max_output_bytes = 1 * 1024 * 1024,
    });
    defer {
        gpa.free(result_of_zig_build_runner.stderr);
        gpa.free(result_of_zig_build_runner.stdout);
    }

    check_exit_code: {
        switch (result_of_zig_build_runner.term) {
            .Exited => |code| if (code == 0) break :check_exit_code else {},
            .Signal, .Stopped, .Unknown => {},
        }

        main_log.err(@src(), "\"zig build\" exited with following code: {}. Possible reasons: crash in build.zig logic, invalid passed arguments etc. Try to pass additional arguments using \"--zig_build_additional_args\", and re-run the generator.", .{result_of_zig_build_runner.term});
    }

    main_log.info(@src(), "Output of \"zig build\":", .{});
    main_log.info(@src(), "STDERR: {s}", .{result_of_zig_build_runner.stderr});
    main_log.info(@src(), "STDOUT: {s}", .{result_of_zig_build_runner.stdout});

    output.lock.timedWait(5 * std.time.ns_per_s) catch |err| switch (err) {
        error.Timeout => {
            main_log.err(@src(), "Timeout: no report from \"zig build\" for 5 seconds, aborting.", .{});
            return;
        },
    };
    var report = output.report;
    main_log.debug(@src(), "report: {}", .{std.json.fmt(report, .{ .whitespace = .indent_2 })});

    var options_status: struct {
        missing_options: std.enums.EnumSet(enum { target, dynamic_linker, cpu }) = .initFull(),
        optimize: enum { all, explicit, none } = .none,
    } = .{};

    const filtered_options = filtered_options: {
        var filtered_options: std.ArrayListUnmanaged(Report.UserOption) = try .initCapacity(gpa, report.user_options.len);
        errdefer filtered_options.deinit(gpa);
        for (report.user_options) |option| {
            if (std.mem.eql(u8, option.name, "target")) {
                options_status.missing_options.toggle(.target);
                continue;
            } else if (std.mem.eql(u8, option.name, "dynamic-linker")) {
                options_status.missing_options.toggle(.dynamic_linker);
                continue;
            } else if (std.mem.eql(u8, option.name, "cpu")) {
                options_status.missing_options.toggle(.cpu);
                continue;
            }

            if (std.mem.eql(u8, option.name, "optimize")) {
                std.debug.assert(std.mem.eql(u8, option.type, "enum"));
                std.debug.assert(options_status.optimize == .none);

                options_status.optimize = .all;
                continue;
            } else if (std.mem.eql(u8, option.name, "release")) {
                std.debug.assert(std.mem.eql(u8, option.type, "bool"));
                std.debug.assert(options_status.optimize == .none);

                options_status.optimize = .explicit;
                continue;
            } else filtered_options.appendAssumeCapacity(option);
        }
        break :filtered_options try filtered_options.toOwnedSlice(gpa);
    };
    defer gpa.free(filtered_options);

    if (options_status.missing_options.count() != 0) {
        main_log.err(@src(), "Package does not have following options ({d}/{d}), which are critical for zig-ebuild.eclass:", .{ options_status.missing_options.count(), options_status.missing_options.bits.capacity() });
        var missing_options = options_status.missing_options.iterator();
        while (missing_options.next()) |missing_option| main_log.err(@src(), " * {s}", .{@tagName(missing_option)});
        main_log.err(@src(), "Fix this using preferred patch way, and then re-run generator.", .{});
    }
    switch (options_status.optimize) {
        .all => {},
        .none => {
            main_log.warn(@src(), "Package does not have \"optimize\" enum, but it has \"release\" boolean option instead. This also means that \"--release=\" option is ignored.", .{});
            main_log.warn(@src(), "If it has any compilable artifacts (executable, libraries etc.), please fix this using preferred patch way, and then re-run generator, otherwise ignore this warning.", .{});
        },
        .explicit => {
            main_log.warn(@src(), "Package does not have \"optimize\" enum, but it has \"release\" boolean option instead. This also means that \"--release=(anything except \"off\")\" option is equivalent to \"-Drelease=true\".", .{});
            main_log.warn(@src(), "For end user executables it may be fine, but if it has other compilable artifacts (libraries etc.) or modules, please fix this using preferred patch way, and then re-run generator, otherwise ignore this warning.", .{});
        },
    }

    report.user_options = filtered_options;

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

const BuildZigZon = struct {
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

    const Dep = struct {
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

    fn deinit(self: *BuildZigZon, allocator: std.mem.Allocator) void {
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
};

const FetchMode = enum { skip, plain, hashed };

const DirLocation = struct {
    string: []const u8,
    dir: std.fs.Dir,

    fn openFile(self: DirLocation, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.File.OpenError)!FileLocation {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const file = try self.dir.openFile(path, .{});
        return .{ .string = string, .file = file };
    }

    fn openDir(self: DirLocation, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.Dir.OpenError)!DirLocation {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const dir = try self.dir.openDir(path, .{});
        return .{ .string = string, .dir = dir };
    }

    fn makeOpenDir(self: DirLocation, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.Dir.MakeError || std.fs.Dir.OpenError || std.fs.Dir.StatFileError)!DirLocation {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const dir = try self.dir.makeOpenPath(path, .{});
        return .{ .string = string, .dir = dir };
    }

    fn deinit(self: *DirLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.string);
        self.dir.close();
    }
};

const FileLocation = struct {
    string: []const u8,
    file: std.fs.File,

    fn openFile(self: FileLocation, allocator: std.mem.Allocator, path: []const u8) (error{OutOfMemory} || std.fs.File.OpenError)!DirLocation {
        const string = try std.fs.path.join(allocator, &.{ self.string, path });
        errdefer allocator.free(string);

        const dir = try self.dir.openDir(path, .{});
        return .{ .string = string, .dir = dir };
    }

    fn deinit(self: FileLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.string);
        self.file.close();
    }
};

fn readBuildZigZon(allocator: std.mem.Allocator, loc: FileLocation, file_parsing_events: Logger) !BuildZigZon {
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

fn createGitCommitDependenciesTarball(
    arena: std.mem.Allocator,
    git_commits: []const GitCommitDep,
    packages_loc: DirLocation,
    writer: anytype,
) !void {
    var full_tar_content: std.ArrayListUnmanaged(u8) = .empty;
    defer full_tar_content.deinit(arena);
    var full_tar = std.tar.writer(full_tar_content.writer(arena).any());
    full_tar.mtime_now = 1;

    for (git_commits) |git_commit_dependency| {
        const archive_file_name = try git_commit_dependency.toFileName(arena);
        defer arena.free(archive_file_name);

        const uncompressed_content = uncompressed_content: {
            var tar_content: std.ArrayListUnmanaged(u8) = .empty;
            errdefer tar_content.deinit(arena);
            const tar_content_writer = tar_content.writer(arena).any();

            var tar = std.tar.writer(tar_content_writer);

            var iterate_dir = try packages_loc.dir.openDir(git_commit_dependency.hash, .{ .iterate = true });
            defer iterate_dir.close();

            var walker = try iterate_dir.walk(arena);
            defer walker.deinit();
            while (try walker.next()) |entry| {
                try tar.writeEntry(entry);
            }
            try tar.finish();

            break :uncompressed_content try tar_content.toOwnedSlice(arena);
        };
        defer arena.free(uncompressed_content);

        const compressed_content = compressed_content: {
            var tar_gz_content: std.ArrayListUnmanaged(u8) = .empty;
            errdefer tar_gz_content.deinit(arena);

            var uncompressed_content_fbs = std.io.fixedBufferStream(uncompressed_content);
            const uncompressed_content_reader = uncompressed_content_fbs.reader();

            try std.compress.gzip.compress(uncompressed_content_reader, tar_gz_content.writer(arena), .{ .level = .default });
            break :compressed_content try tar_gz_content.toOwnedSlice(arena);
        };
        defer arena.free(compressed_content);

        try full_tar.writeFileBytes(archive_file_name, compressed_content, .{});
    }
    try full_tar.finish();

    var tar_reader_fbs = std.io.fixedBufferStream(full_tar_content.items);
    try std.compress.gzip.compress(tar_reader_fbs.reader(), writer, .{ .level = .default });
}

const VendorUri = struct {
    name: []const u8,
    /// TODO: many urls? mirrors?
    url: []const u8,
};

const GitCommitDep = struct {
    name: []const u8,
    hash: []const u8,

    fn toFileName(self: GitCommitDep, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}-{s}.{s}", .{ self.name, self.hash, @tagName(FileType.@"tar.gz") });
    }
};

const Dependencies = struct {
    /// URLs that are successfully parsed or translated to tarball URLs.
    tarball: []const VendorUri,
    /// URLs that are needed to be packaged by maintainer themselves.
    git_commit: []const GitCommitDep,

    fn deinit(self: Dependencies, allocator: std.mem.Allocator) void {
        for (self.tarball) |tarball| {
            allocator.free(tarball.name);
            allocator.free(tarball.url);
        }
        allocator.free(self.tarball);

        for (self.git_commit) |git_commit| {
            allocator.free(git_commit.hash);
            allocator.free(git_commit.name);
        }
        allocator.free(self.git_commit);
    }
};

fn generateDependenciesArray(
    /// All data allocated by this allocator is saved.
    gpa: std.mem.Allocator,
    /// All data allocated by this allocator should be cleaned by caller.
    arena: std.mem.Allocator,
    //
    project_build_zig_zon_struct: BuildZigZon,
    project_loc: DirLocation,
    dependencies_loc: DirLocation,
    packages_loc: DirLocation,
    file_events: Logger,
    env_map: *const std.process.EnvMap,
) !Dependencies {
    // Keyed by `hash`
    var vendor_urls_map: std.StringArrayHashMapUnmanaged(VendorUri) = .empty;
    defer vendor_urls_map.deinit(arena);

    var fifo: std.fifo.LinearFifo(struct { DirLocation, BuildZigZon }, .Dynamic) = .init(arena);
    defer fifo.deinit();
    try fifo.writeItem(.{ project_loc, project_build_zig_zon_struct });

    var first_item = true;
    while (fifo.readItem()) |pair| {
        var location, const build_zig_zon_struct = pair;
        defer {
            if (first_item == false) location.deinit(arena);
            first_item = false;
        }

        file_events.debug(@src(), "build_zig_zon_struct: {any}", .{std.json.fmt(build_zig_zon_struct, .{ .whitespace = .indent_2 })});

        const dependencies = build_zig_zon_struct.dependencies orelse continue;

        var all_paths: std.ArrayListUnmanaged(struct {
            hash: []const u8,
            name: []const u8,
            storage: union(enum) {
                remote: struct { url: []const u8 },
                local: void,
            },
        }) = try .initCapacity(arena, dependencies.map.count());
        defer all_paths.deinit(arena);

        for (dependencies.map.keys(), dependencies.map.values(), 0..) |key, value, i| {
            switch (global.fetch_mode) {
                .skip => continue,
                .hashed, .plain => {},
            }

            file_events.info(@src(), "Fetching \"{s}\" [{d}/{d}]...", .{ key, i + 1, dependencies.map.count() });

            const dir_to_fetch = switch (value.storage) {
                .remote => |remote| remote.url,
                .local => |local| local.path,
            };

            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            defer argv.deinit(arena);
            try argv.appendSlice(arena, &.{
                global.zig_executable,
                "fetch",
                "--global-cache-dir",
                dependencies_loc.string,
                dir_to_fetch,
            });
            switch (global.fetch_mode) {
                .hashed => switch (value.storage) {
                    .remote => |remote| try argv.append(arena, remote.hash),
                    .local => {},
                },
                .plain => {},
                .skip => @panic("unreachable"),
            }

            file_events.debug(@src(), "Running command: cd \"{!s}\" && {s}", .{ location.string, argv.items });

            const result_of_fetch = try std.process.Child.run(.{
                .allocator = arena,
                .argv = argv.items,
                .cwd_dir = location.dir,
                .env_map = env_map,
                .max_output_bytes = 1 * 1024,
            });
            defer arena.free(result_of_fetch.stderr);

            if (result_of_fetch.stderr.len != 0) {
                file_events.err(@src(), "Error when fetching dependency \"{s}\". Details are in DEBUG.", .{key});
                file_events.debug(@src(), "{s}", .{result_of_fetch.stderr});
                return error.FetchFailed;
            }

            all_paths.appendAssumeCapacity(.{
                .hash = std.mem.trim(u8, result_of_fetch.stdout, &std.ascii.whitespace),
                .name = key,
                .storage = switch (value.storage) {
                    .remote => |remote| .{ .remote = .{ .url = remote.url } },
                    .local => .local,
                },
            });
        }

        for (all_paths.items) |item| {
            var package_loc = try packages_loc.openDir(arena, item.hash);
            errdefer package_loc.deinit(arena);

            file_events.debug(@src(), "searching {s}...", .{package_loc.string});

            var next_build_zig_zon_struct: BuildZigZon = zon: {
                const package_build_zig_zon_loc = package_loc.openFile(arena, "build.zig.zon") catch |err| switch (err) {
                    // It might be a plain package, without build.zig.zon
                    error.FileNotFound => break :zon .{
                        .name = "", // replaced below
                        // After that, all is ignored RN.
                        .version = .{ .major = 0, .minor = 0, .patch = 0 },
                        .version_raw = "",
                        .minimum_zig_version = null,
                        .minimum_zig_version_raw = null,
                        .dependencies = null,
                        .paths = &.{""},
                    },
                    else => |e| return e,
                };
                defer package_build_zig_zon_loc.deinit(arena);

                break :zon try readBuildZigZon(arena, package_build_zig_zon_loc, file_events);
            };
            if (next_build_zig_zon_struct.name.len == 0)
                next_build_zig_zon_struct.name = item.name;

            try fifo.writeItem(.{ package_loc, next_build_zig_zon_struct });
            switch (item.storage) {
                .local => continue,
                .remote => |remote| {
                    const new: VendorUri = .{
                        .name = next_build_zig_zon_struct.name,
                        .url = remote.url,
                    };

                    const result = try vendor_urls_map.getOrPut(arena, item.hash);
                    result.value_ptr.* = if (result.found_existing == false) new else resolve_conflict: {
                        const old = result.value_ptr.*;
                        switch (std.mem.eql(u8, old.url, new.url)) {
                            true => {
                                // TODO maybe also compare names?
                                file_events.warn(@src(), "Found 2 package variants with identical URLs. Ignoring names, leaving old. Old name: {s}, new name: {s}, URL: {s}", .{ old.name, new.name, old.url });
                                break :resolve_conflict old;
                            },
                            else => {
                                const old_uri = std.Uri.parse(old.url) catch |err| {
                                    file_events.err(@src(), "Invalid URI \"{s}\": {s}", .{ old.url, @errorName(err) });
                                    return error.InvalidBuildZigZon;
                                };
                                const new_uri = std.Uri.parse(new.url) catch |err| {
                                    file_events.err(@src(), "Invalid URI \"{s}\": {s}", .{ new.url, @errorName(err) });
                                    return error.InvalidBuildZigZon;
                                };

                                if ((std.ascii.eqlIgnoreCase(old_uri.scheme, "https") or
                                    std.ascii.eqlIgnoreCase(old_uri.scheme, "http")) and
                                    (std.ascii.eqlIgnoreCase(new_uri.scheme, "git+https") or
                                    std.ascii.eqlIgnoreCase(new_uri.scheme, "git+http")))
                                {
                                    file_events.warn(@src(), "Found 2 package variants with different URIs: tarball and Git commit. Leaving tarball. Tarball variant: {any}, commit variant: {any}", .{
                                        std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                        std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                    });
                                    break :resolve_conflict old;
                                } else if ((std.ascii.eqlIgnoreCase(old_uri.scheme, "git+https") or
                                    std.ascii.eqlIgnoreCase(old_uri.scheme, "git+http")) and
                                    (std.ascii.eqlIgnoreCase(new_uri.scheme, "https") or
                                    std.ascii.eqlIgnoreCase(new_uri.scheme, "http")))
                                {
                                    file_events.warn(@src(), "Found 2 package variants with different URIs: Git commit and tarball. Changing to tarball. Commit variant: {any}, tarball variant: {any}", .{
                                        std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                        std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                    });
                                    break :resolve_conflict new;
                                } else std.debug.panic("TODO (please report to upstream of zig-ebuilder): resolve conflict: existing: {any}, new: {any}", .{
                                    std.json.fmt(old, .{ .whitespace = .indent_2 }),
                                    std.json.fmt(new, .{ .whitespace = .indent_2 }),
                                });
                            },
                        }
                    };
                },
            }
        }
    }

    file_events.info(@src(), "Vendor URLs count: {d}", .{vendor_urls_map.count()});

    const Sort = struct {
        keys: []VendorUri,

        pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
            return switch (std.mem.order(u8, ctx.keys[a_index].name, ctx.keys[b_index].name)) {
                .lt => true,
                .eq => false,
                .gt => false,
            };
        }
    };

    vendor_urls_map.sort(Sort{ .keys = vendor_urls_map.values() });

    var array: std.ArrayListUnmanaged(VendorUri) = try .initCapacity(gpa, vendor_urls_map.count());
    errdefer array.deinit(gpa);

    var packaging_needed: std.ArrayListUnmanaged(GitCommitDep) = try .initCapacity(gpa, vendor_urls_map.count());
    errdefer packaging_needed.deinit(gpa);

    for (vendor_urls_map.keys(), vendor_urls_map.values()) |hash, dep| {
        const uri = std.Uri.parse(dep.url) catch @panic("unreachable (report to upstream of zig-ebuilder)");

        var name: std.ArrayListUnmanaged(u8) = .empty;
        defer name.deinit(gpa);
        var url: std.ArrayListUnmanaged(u8) = .empty;
        defer url.deinit(gpa);

        const name_writer = name.writer(gpa);
        const url_writer = url.writer(gpa);

        // Print everything 'raw' so that Mustache template
        // can percent-encode it by itself.
        const ext: FileType = if (std.ascii.eqlIgnoreCase(uri.scheme, "git+https") or std.ascii.eqlIgnoreCase(uri.scheme, "git+http")) git: {
            // Services for which mapping "Git commit to archive"
            // is well known and relatively stable.
            const GitService = enum {
                /// Codeberg.
                codeberg,
                /// GitHub main instance (not Enterprise).
                github,
                /// GitLab official instance.
                gitlab,
                /// SourceHut Git instance.
                sourcehut,

                /// Base URL, without trailing slash,
                /// stripped of "www." etc. prefix if possible,
                /// and prefers "https" over "http" if possible.
                fn toUrl(self: @This()) []const u8 {
                    return switch (self) {
                        .codeberg => "https://codeberg.org",
                        .github => "https://github.com",
                        .gitlab => "https://gitlab.com",
                        .sourcehut => "https://git.sr.ht",
                    };
                }

                const fromHost: std.StaticStringMap(@This()) = .initComptime(.{
                    .{ "codeberg.org", .codeberg },
                    .{ "www.codeberg.org", .codeberg },

                    .{ "github.com", .github },
                    .{ "www.github.com", .github },

                    .{ "gitlab.com", .gitlab },
                    .{ "www.gitlab.com", .gitlab },

                    // As of 2024 no "www." variant or redirect:
                    .{ "git.sr.ht", .sourcehut },
                });
            };

            // Assuming it is a commit. If "zig fetch" was called by author:
            // * with "--save" option: tags are rewritten as commits,
            // * with "--save-exact" option: tags are not rewritten.
            const commit = uri.fragment orelse @panic("TODO: what to do with exact-saved mutable data (like git+https://...#<tag>)? They should really point to immutable data (like what zig fetch --save would do here, using \"?ref=<tag>#commit\") but IDK how to message it to the authors...");
            const host = try uri.host.?.toRawMaybeAlloc(arena);
            const service = GitService.fromHost.get(host) orelse {
                packaging_needed.appendAssumeCapacity(.{
                    .name = try GitCommitDep.toFileName(.{ .name = dep.name, .hash = hash }, gpa),
                    .hash = try gpa.dupe(u8, hash),
                });
                continue;
            };

            var repository = try uri.path.toRawMaybeAlloc(arena);
            std.debug.assert(std.mem.startsWith(u8, repository, "/"));
            switch (service) {
                .codeberg, .github, .sourcehut, .gitlab => if (std.mem.endsWith(u8, repository, ".git")) {
                    repository = repository[0 .. repository.len - ".git".len];
                },
            }

            switch (service) {
                .codeberg, .github, .sourcehut => |s| {
                    try url_writer.print("{s}{s}/archive/{raw}.tar.gz", .{ s.toUrl(), repository, commit });
                    break :git .@"tar.gz";
                },
                .gitlab => |s| {
                    // TODO: Change to ".tar.bz2" when/if `zig fetch` start to support it.
                    try url_writer.print("{s}{s}/-/archive/{raw}.tar.gz", .{ s.toUrl(), repository, commit });
                    break :git .@"tar.gz";
                },
            }
        }
        // If not a commit, then tarball.
        else tarball: {
            try url_writer.print("{s}", .{dep.url});
            break :tarball FileType.fromPath(dep.url) orelse std.debug.panic("Unknown tarball extension for: {s}", .{dep.url});
        };

        try name_writer.print("{s}-{s}.{s}", .{ dep.name, hash, @tagName(ext) });

        array.appendAssumeCapacity(.{
            .name = try name.toOwnedSlice(gpa),
            .url = try url.toOwnedSlice(gpa),
        });
    }

    return .{
        .tarball = try array.toOwnedSlice(gpa),
        .git_commit = try packaging_needed.toOwnedSlice(gpa),
    };
}

const FullReport = struct {
    lock: std.Thread.ResetEvent,
    report: Report,
};

const Report = struct {
    system_libraries: []const SystemLibrary,
    system_integrations: []const []const u8,
    user_options: []const UserOption,

    const SystemLibrary = struct {
        name: []const u8,
        used_by: []const []const u8,
    };
    const UserOption = struct {
        name: []const u8,
        description: []const u8,
        type: []const u8,
        values: ?[]const []const u8,
    };
};

fn receiveReport(arena: std.mem.Allocator, server: *std.net.Server, result: *FullReport) !void {
    std.debug.assert(result.lock.isSet() == false);
    while (true) {
        // Blocks thread
        const conn = server.accept() catch |err| {
            std.debug.print("Error when accepting connection to report server: {s}\n", .{@errorName(err)});
            return err;
        };

        const stream = conn.stream;
        defer stream.close();

        const content = try stream.reader().readAllAlloc(arena, 1 * 1024 * 1024);
        defer arena.free(content);

        //main_log.debug(@src(), "content = {s}", .{content});
        const json = std.json.parseFromSliceLeaky(Report, arena, content, .{ .allocate = .alloc_always }) catch |err| {
            std.debug.print("Error when parsing report from a server: {s}\n", .{@errorName(err)});
            return err;
        };
        result.report = json;
        break;
    }
    result.lock.set();
}

// Copied from Zig compiler sources ("src/package/Fetch.zig"
// as for upstream commit ea527f7a850f0200681630d8f36131eca31ef48b).
// SPDX-SnippetBegin
// SPDX-SnippetCopyrightText: Zig contributors
// SPDX-License-Identifier: MIT
const FileType = enum {
    tar,
    @"tar.gz",
    @"tar.bz2",
    @"tar.xz",
    @"tar.zst",
    git_pack,
    zip,

    fn fromPath(file_path: []const u8) ?@This() {
        const ascii = std.ascii;
        if (ascii.endsWithIgnoreCase(file_path, ".tar")) return .tar;
        // TODO enable when/if `zig fetch` starts to support it.
        // if (ascii.endsWithIgnoreCase(file_path, ".tar.bz2")) return .@"tar.bz2";
        if (ascii.endsWithIgnoreCase(file_path, ".tgz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.gz")) return .@"tar.gz";
        if (ascii.endsWithIgnoreCase(file_path, ".txz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.xz")) return .@"tar.xz";
        if (ascii.endsWithIgnoreCase(file_path, ".tzst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(file_path, ".tar.zst")) return .@"tar.zst";
        if (ascii.endsWithIgnoreCase(file_path, ".zip")) return .zip;
        return null;
    }
};
// SPDX-SnippetEnd
