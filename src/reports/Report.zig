// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: EUPL-1.2

const std = @import("std");

const Logger = @import("../Logger.zig");
const ZigProcess = @import("../ZigProcess.zig");

const setup = @import("../setup.zig");

const Report = @This();

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

fn get_build_runner_name_suffix(zig_version: ZigProcess.Version) error{BuildRunnerNotFound}![]const u8 {
    return switch (zig_version.kind) {
        .live => "live",
        .release => if (zig_version.sem_ver.major == 0 and zig_version.sem_ver.minor == 13)
            "0.13"
        else
            return error.BuildRunnerNotFound,
    };
}

pub fn collect(
    gpa: std.mem.Allocator,
    env_map: *std.process.EnvMap,
    generator_setup: setup.Generator,
    main_log: Logger,
    zig_build_additional_args: [][:0]const u8,
    project_setup: setup.Project,
    zig_process: ZigProcess,
    /// Used to store result.
    arena: std.mem.Allocator,
) !Report {
    const build_runner_name_suffix = get_build_runner_name_suffix(zig_process.version) catch {
        main_log.err(@src(), "No build runner found for Zig {}, please report to zig-ebuilder upstream.", .{zig_process.version.sem_ver});
        main_log.err(@src(), "Available build runners: {s}.", .{[2][]const u8{ "live", "0.13" }});
        return error.BuildRunnerNotFound;
    };

    const build_runner_text = if (std.mem.eql(u8, build_runner_name_suffix, "live"))
        @embedFile("build_runner_live.zig")
    else if (std.mem.eql(u8, build_runner_name_suffix, "0.13"))
        @embedFile("build_runner_0.13.zig")
    else
        @panic("unreachable");

    const hashed_name = hashed_name: {
        const hash_suffix = std.Build.Cache.HashHelper.oneShot(build_runner_text);
        break :hashed_name try std.fmt.allocPrint(gpa, "{s}_{s}.zig", .{ get_build_runner_name_suffix(zig_process.version) catch @panic("unreachable"), hash_suffix });
    };
    defer gpa.free(hashed_name);

    var build_runners_loc = try generator_setup.cache.makeOpenDir(gpa, "build_runners");
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

    var report: Report = .{
        .system_libraries = undefined,
        .system_integrations = undefined,
        .user_options = undefined,
    };

    // Spawns thread
    var lock: std.Thread.ResetEvent = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = 16 * 1024 }, receive, .{ arena, &report_server, &lock, &report });
    thread.detach();

    // Blocks thread
    const result_of_zig_build_runner = try zig_process.build(
        gpa,
        project_setup,
        .{
            .build_runner_path = build_runner_path,
            .packages_loc = generator_setup.packages,
            .additional = zig_build_additional_args,
        },
        main_log,
    );
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

    // Blocks thread
    lock.timedWait(5 * std.time.ns_per_s) catch |err| switch (err) {
        error.Timeout => {
            main_log.err(@src(), "Timeout: no report from \"zig build\" for 5 seconds, aborting.", .{});
            return error.Timeout;
        },
    };

    main_log.debug(@src(), "report (before transformation): {}", .{
        std.json.fmt(report, .{ .whitespace = .indent_2 }),
    });

    var options_status: struct {
        missing_options: std.enums.EnumSet(enum { target, dynamic_linker, cpu }) = .initFull(),
        optimize: enum { all, explicit, none } = .none,
    } = .{};

    const filtered_options = filtered_options: {
        var filtered_options: std.ArrayListUnmanaged(Report.UserOption) = try .initCapacity(arena, report.user_options.len);
        errdefer filtered_options.deinit(arena);
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
        break :filtered_options try filtered_options.toOwnedSlice(arena);
    };
    errdefer arena.free(filtered_options);

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
    return report;
}

fn receive(arena: std.mem.Allocator, server: *std.net.Server, lock: *std.Thread.ResetEvent, result: *Report) !void {
    std.debug.assert(lock.isSet() == false);
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
        const json_parsed = std.json.parseFromSliceLeaky(Report, arena, content, .{ .allocate = .alloc_always }) catch |err| {
            std.debug.print("Error when parsing report from a server: {s}\n", .{@errorName(err)});
            return err;
        };
        result.* = json_parsed;
        break;
    }
    lock.set();
}
