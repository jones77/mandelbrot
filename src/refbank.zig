const std = @import("std");
const m = @import("mandelbrot.zig");

const GridPoint = struct { cx: f64, cy: f64 };

/// Generate grid points covering a viewport.
/// Returns a flat array of (cx, cy) pairs allocated with `allocator`.
/// The first entry is the viewport center; remaining entries form a
/// `grid_cols x grid_rows` rectangular grid.
pub fn generateGridPoints(
    allocator: std.mem.Allocator,
    center_x: f64,
    center_y: f64,
    range_x: f64,
    range_y: f64,
    grid_cols: usize,
    grid_rows: usize,
) ![]GridPoint {
    const count: usize = 1 + grid_cols * grid_rows;
    const points = try allocator.alloc(GridPoint, count);

    points[0] = .{ .cx = center_x, .cy = center_y };

    var idx: usize = 1;
    for (0..grid_rows) |row| {
        const t_y = (@as(f64, @floatFromInt(row)) + 0.5) / @as(f64, @floatFromInt(grid_rows));
        for (0..grid_cols) |col| {
            const t_x = (@as(f64, @floatFromInt(col)) + 0.5) / @as(f64, @floatFromInt(grid_cols));
            points[idx] = .{
                .cx = center_x + (t_x - 0.5) * range_x,
                .cy = center_y + (t_y - 0.5) * range_y,
            };
            idx += 1;
        }
    }
    return points;
}

/// Build a RefBank by computing reference orbits at each grid point.
/// `grid_cols x grid_rows` defines the grid density.
/// The caller must call `.deinit()` on the returned RefBank.
pub fn buildRefBank(
    allocator: std.mem.Allocator,
    center_x: f64,
    center_y: f64,
    range_x: f64,
    range_y: f64,
    max_iters: u32,
    grid_cols: usize,
    grid_rows: usize,
) !m.RefBank {
    const points = try generateGridPoints(allocator, center_x, center_y, range_x, range_y, grid_cols, grid_rows);
    defer allocator.free(points);

    const entries = try allocator.alloc(m.RefBankEntry, points.len);
    errdefer allocator.free(entries);

    for (points, 0..) |pt, i| {
        const orbit = try m.computeReference(pt.cx, pt.cy, max_iters, allocator);
        const last = orbit[orbit.len - 1];
        const nsq = last.zx * last.zx + last.zy * last.zy;
        const escaped = !std.math.isFinite(nsq) or nsq > m.ESCAPE_RADIUS_SQ;

        const gcf = if (i == 0) 0.5 else (@as(f64, @floatFromInt((i - 1) % grid_cols)) + 0.5) / @as(f64, @floatFromInt(grid_cols));
        const grf = if (i == 0) 0.5 else (@as(f64, @floatFromInt((i - 1) / grid_cols)) + 0.5) / @as(f64, @floatFromInt(grid_rows));
        entries[i] = .{
            .orbit = orbit,
            .cx = pt.cx,
            .cy = pt.cy,
            .escaped = escaped,
            .grid_col_frac = gcf,
            .grid_row_frac = grf,
            .rel_cx = pt.cx - center_x,
            .rel_cy = pt.cy - center_y,
        };
    }

    return .{
        .entries = entries,
        .cols = grid_cols,
        .rows = grid_rows,
        .allocator = allocator,
    };
}

test "generateGridPoints produces expected count and layout" {
    const alloc = std.testing.allocator;
    const pts = try generateGridPoints(alloc, 0.0, 0.0, 4.0, 4.0, 2, 2);
    defer alloc.free(pts);

    try std.testing.expectEqual(@as(usize, 5), pts.len);

    try std.testing.expectEqual(@as(f64, 0.0), pts[0].cx);
    try std.testing.expectEqual(@as(f64, 0.0), pts[0].cy);

    for (pts) |p| {
        try std.testing.expect(p.cx >= -2.0 and p.cx <= 2.0);
        try std.testing.expect(p.cy >= -2.0 and p.cy <= 2.0);
    }
}

test "buildRefBank computes orbits for all grid points" {
    const alloc = std.testing.allocator;
    var bank = try buildRefBank(alloc, -0.75, 0.0, 3.0, 3.0, 64, 2, 2);
    defer bank.deinit();

    try std.testing.expectEqual(@as(usize, 5), bank.entries.len);
    try std.testing.expectEqual(@as(usize, 2), bank.cols);
    try std.testing.expectEqual(@as(usize, 2), bank.rows);

    try std.testing.expect(bank.escapedCount() > 0);
}
