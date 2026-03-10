const std = @import("std");
const Allocator = std.mem.Allocator;
const DirEntry = @import("bin").DirEntry;

const colormaps = @import("colormaps.zig");

const rl = @import("raylib");

pub fn squarify(alloc: Allocator, dir_entries: []const DirEntry, rect: rl.Rectangle) void {
    // TODO: scaleWeights?
    // this.scaleWeights(nodes, width, height);
    std.debug.assert(std.sort.isSorted(DirEntry, dir_entries, {}, DirEntry.gt_than));

    const min_aggregate_percent: f32 = 0.0001;

    const weights = alloc.alloc(f32, dir_entries.len) catch unreachable;
    {
        var sum_: f32 = 0;
        for (dir_entries) |d| {
            sum_ += @floatFromInt(d.size_bytes);
        }

        const scale = (rect.width * rect.height) / sum_;
        for (dir_entries, weights) |d, *w| {
            w.* = scale * @as(f32, @floatFromInt(d.size_bytes));
        }
    }
    const colors = generate_palette(alloc, weights, .{ .sample = .verdis }) catch unreachable;

    // background
    rl.drawRectangleRec(rect, .light_gray);

    var vertical = rect.height < rect.width;
    var x = rect.x;
    var y = rect.y;
    var rw = rect.width;
    var rh = rect.height;

    var row = std.ArrayList(DirEntry).initCapacity(alloc, dir_entries.len) catch unreachable;
    var row_weights = std.ArrayList(f32).initCapacity(alloc, dir_entries.len) catch unreachable;
    var row_colors = std.ArrayList(rl.Color).initCapacity(alloc, dir_entries.len) catch unreachable;

    var i: u32 = 0;
    while (i < dir_entries.len) {
        const c = dir_entries[i];
        const r: f32 = weights[i];
        const remaining_percent = r / (rect.width * rect.height);

        if (row.items.len == 0 and remaining_percent < min_aggregate_percent) {
            util.draw_rect(
                .{ .x = x, .y = y, .width = rw, .height = rh },
                colors[i],
            );
            return;
        }

        const row_sum = util.sum(row_weights.items);
        const min = util.min(row_weights.items);
        const max = util.max(row_weights.items);
        const w = if (vertical) rh else rw;
        const wit = util.worst(row_sum + r, @min(min, r), @max(max, r), w);
        const without = util.worst(row_sum, min, max, w);
        if (row.items.len == 0 or wit < without) {
            row.appendAssumeCapacity(c);
            row_weights.appendAssumeCapacity(r);
            row_colors.appendAssumeCapacity(colors[i]);
            i += 1;
            continue;
        }

        util.flush_row(
            vertical,
            &x,
            &y,
            &rw,
            &rh,
            row_weights.items,
            row_colors.items,
        );

        vertical = rh < rw;
        row.clearRetainingCapacity();
        row_weights.clearRetainingCapacity();
        row_colors.clearRetainingCapacity();
    }

    if (row_weights.items.len > 0) {
        const row_percent = util.sum(row_weights.items) / (rect.width * rect.height);
        if (row_percent < min_aggregate_percent) {
            util.draw_rect(
                .{ .x = x, .y = y, .width = rw, .height = rh },
                row_colors.items[0],
            );
        } else {
            util.flush_row(
                vertical,
                &x,
                &y,
                &rw,
                &rh,
                row_weights.items,
                row_colors.items,
            );
        }
    }
}

const util = struct {
    fn sum(row: []const f32) f32 {
        var sum_: f32 = 0;
        for (row) |d| {
            sum_ += d;
        }
        return sum_;
    }
    fn min(row: []const f32) f32 {
        var min_: f32 = std.math.floatMax(f32);
        for (row) |d| {
            min_ = @min(min_, d);
        }
        return min_;
    }
    fn max(row: []const f32) f32 {
        var max_: f32 = 0;
        for (row) |d| {
            max_ = @max(max_, d);
        }
        return max_;
    }

    fn worst(s: f32, min_: f32, max_: f32, w: f32) f32 {
        return @max((w * w * max_) / (s * s), (s * s) / (w * w * min_));
    }

    fn draw_rect(rec: rl.Rectangle, color: rl.Color) void {
        const border_width: f32 = 3.0;
        var inset = rec;
        inset.x += border_width / 2;
        inset.y += border_width / 2;
        inset.width -= border_width / 2;
        inset.height -= border_width / 2;
        if (inset.width <= 0 or inset.height <= 0) return;
        rl.drawRectangleRec(inset, color);
    }

    fn flush_row(
        vertical: bool,
        x: *f32,
        y: *f32,
        rw: *f32,
        rh: *f32,
        row_weights: []const f32,
        row_colors: []const rl.Color,
    ) void {
        if (row_weights.len == 0) return;

        var rx = x.*;
        var ry = y.*;
        const s = sum(row_weights);
        const w = if (vertical) rh.* else rw.*;
        const z = s / w;

        for (0..row_weights.len) |j| {
            const d = row_weights[j] / z;
            const color = row_colors[j];
            const rec: rl.Rectangle = if (vertical)
                .{ .x = rx, .y = ry, .width = z, .height = d }
            else
                .{ .x = rx, .y = ry, .width = d, .height = z };

            if (vertical) {
                ry += d;
            } else {
                rx += d;
            }

            draw_rect(rec, color);
        }

        if (vertical) {
            x.* += z;
            rw.* -= z;
        } else {
            y.* += z;
            rh.* -= z;
        }
    }
};

pub const ColorScheme = union(enum) {
    rainbow: void,
    sample: colormaps.options,
};

fn generate_palette(
    alloc: Allocator,
    weights: []const f32,
    scheme: ColorScheme,
) ![]rl.Color {
    if (weights.len == 0) return &[_]rl.Color{};

    const colormap = switch (scheme) {
        .rainbow => rainbowColor,
        .sample => |sample_scheme| switch (sample_scheme) {
            inline else => |value| colormapColor(value),
        },
    };
    // Find min and max weights for normalization
    var min_weight: f32 = weights[0];
    var max_weight: f32 = weights[0];

    for (weights) |w| {
        min_weight = @min(min_weight, w);
        max_weight = @max(max_weight, w);
    }

    const range = max_weight - min_weight;

    // Generate colors
    var colors = try alloc.alloc(rl.Color, weights.len);

    for (weights, 0..) |w, i| {
        const normalized = if (range == 0.0) 0.0 else (w - min_weight) / range;
        const color = colormap(normalized);
        colors[i] = rl.colorFromNormalized(.{
            .x = color.r,
            .y = color.g,
            .z = color.b,
            .w = 1.0,
        });
    }

    return colors;
}

/// Rainbow color map (follows the HSV color wheel)
pub fn rainbowColor(value: f32) RGB {
    const v = std.math.clamp(value, 0.0, 1.0);
    const h = 1.0 - v; // Reverse direction to match common rainbow maps

    // Convert HSV to RGB (simplified for hue only, S=V=1)
    const h_i: u32 = @intFromFloat(h * 6.0);
    const f = h * 6.0 - @as(f32, @floatFromInt(h_i));
    const p = 0.0;
    const q = 1.0 - f;
    const t = f;

    switch (h_i) {
        0 => return RGB{ .r = 1.0, .g = t, .b = p },
        1 => return RGB{ .r = q, .g = 1.0, .b = p },
        2 => return RGB{ .r = p, .g = 1.0, .b = t },
        3 => return RGB{ .r = p, .g = q, .b = 1.0 },
        4 => return RGB{ .r = t, .g = p, .b = 1.0 },
        else => return RGB{ .r = 1.0, .g = p, .b = q },
    }
}

pub fn colormapColor(comptime sample: colormaps.options) *const fn (f32) RGB {
    const map = comptime sample.map();
    const inverse = switch (sample) {
        .turbo => false,
        else => true,
    };

    return struct {
        fn get(value: f32) RGB {
            const v = std.math.clamp(value, 0.0, 1.0);

            const segment = (if (inverse) 1.0 - v else v) * (@as(f32, @floatFromInt(map.len)) - 1.0);
            const i: usize = @intFromFloat(segment);
            const t = segment - @floor(segment);

            if (i >= map.len - 1) return RGB.from_arr(map[map.len - 1]);
            return lerpColor(RGB.from_arr(map[i]), RGB.from_arr(map[i + 1]), t);
        }
    }.get;
}

/// RGB color structure with values between 0 and 1
pub const RGB = struct {
    r: f32,
    g: f32,
    b: f32,

    pub fn from_arr(rgb: [3]f32) RGB {
        return RGB{
            .r = rgb[0],
            .g = rgb[1],
            .b = rgb[2],
        };
    }
};

/// Linear interpolation between two values
fn lerp(start: f32, end: f32, t: f32) f32 {
    return start + t * (end - start);
}

/// Linear interpolation between two RGB colors
fn lerpColor(c1: RGB, c2: RGB, t: f32) RGB {
    return RGB{
        .r = lerp(c1.r, c2.r, t),
        .g = lerp(c1.g, c2.g, t),
        .b = lerp(c1.b, c2.b, t),
    };
}
