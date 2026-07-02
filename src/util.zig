const std = @import("std");

pub const PIXEL_CHANNELS: u32 = 4;

extern "c" fn clock_gettime(clock_id: c_int, tp: *std.c.timespec) c_int;

pub fn isoNow(buf: []u8) []u8 {
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(@intFromEnum(std.c.CLOCK.REALTIME), &ts);
    const secs: u64 = @intCast(ts.sec);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const day_secs = epoch.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const h = day_secs.getHoursIntoDay();
    const min = day_secs.getMinutesIntoHour();
    const s = day_secs.getSecondsIntoMinute();
    const ms = @as(u32, @intCast(ts.nsec)) / 1_000_000;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        h, min, s, ms,
    }) catch unreachable;
}

pub fn logEvent(comptime scope: anytype, comptime fmt: []const u8, args: anytype) void {
    var ts_buf: [24]u8 = undefined;
    const ts = isoNow(&ts_buf);
    std.debug.print("{s} [{s}] ", .{ ts, @tagName(scope) });
    std.debug.print(fmt, args);
    std.debug.print("\n", .{});
}

const testing = std.testing;

test "isoNow format" {
    var buf: [24]u8 = undefined;
    const ts = isoNow(&buf);
    try testing.expectEqual(@as(usize, 24), ts.len);
    // ISO 8601 basic format: YYYY-MM-DDTHH:MM:SS.mmmZ (24 chars)
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    try testing.expectEqual(@as(u8, 'Z'), ts[23]);
    try testing.expectEqual(@as(u8, '-'), ts[4]);
    try testing.expectEqual(@as(u8, '-'), ts[7]);
    try testing.expectEqual(@as(u8, ':'), ts[13]);
    try testing.expectEqual(@as(u8, ':'), ts[16]);
    try testing.expectEqual(@as(u8, '.'), ts[19]);
}


