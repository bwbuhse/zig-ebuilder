// SPDX-FileCopyrightText: 2024 BratishkaErik
//
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Timestamp = @This();

year: std.time.epoch.Year,
month: u4,
day: u5,
hour: u5,
minute: u6,
second: u6,

pub fn now() Timestamp {
    const seconds = @max(0, std.time.timestamp());
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    return from_epoch_seconds(epoch_seconds);
}

pub fn from_epoch_seconds(epoch_seconds: std.time.epoch.EpochSeconds) Timestamp {
    // 1 year and 355th day f.e.
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const year = year_day.year;

    // 10 month and 4th day f.e.
    const month_day = year_day.calculateMonthDay();
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    // 10 hour, 9 minute and 8 seconds f.e.
    const day_seconds = epoch_seconds.getDaySeconds();
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

pub fn format(
    self: Timestamp,
    comptime spec: []const u8,
    // UPSTREAM https://github.com/ziglang/zig/issues/20152
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    if (comptime std.mem.eql(u8, spec, "time")) {
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });
    } else if (comptime std.mem.eql(u8, spec, "day")) {
        try writer.print("{d}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
    } else @compileError("Unknown spec: " ++ spec ++ ". Should be one of: time, day.");
}
