// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: CC0-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_bin = b.option(bool, "no-bin", "Do not output anything, trigger analysis only (useful for incremental compilation) (default: false)") orelse false;

    const dep_mustache = b.dependency("mustache", .{ .target = target, .optimize = optimize });
    const mod_mustache = dep_mustache.module("mustache");

    const exe = b.addExecutable(.{
        .name = "zig-ebuilder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mustache", mod_mustache);

    b.installDirectory(std.Build.Step.InstallDir.Options{
        .install_dir = .{ .custom = "share" },
        .install_subdir = "zig-ebuilder",
        .source_dir = b.path("share/"),
    });

    if (no_bin)
        b.getInstallStep().dependOn(&exe.step)
    else
        b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("mustache", mod_mustache);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
