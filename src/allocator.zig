const std = @import("std");
const buildopts = @import("buildopts");
const logEvent = @import("log.zig").logEvent;

const use_gpa = buildopts.use_gpa;

const DA = std.heap.DebugAllocator(.{ .safety = true, .never_unmap = true });
var debug_alloc: DA = .{};
var initialized = false;

pub fn get() std.mem.Allocator {
    if (!initialized) {
        initialized = true;
        if (use_gpa) {
            logEvent(.alloc, "DebugAllocator{{safety,never_unmap}}", .{});
        } else {
            logEvent(.alloc, "page_allocator", .{});
        }
    }
    return if (use_gpa) debug_alloc.allocator() else std.heap.page_allocator;
}

pub fn deinit() void {
    if (use_gpa and debug_alloc.deinit() == .leak) {
        logEvent(.alloc, "memory leak detected", .{});
    }
}
