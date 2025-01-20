const std = @import("std");
const lib = @import("root.zig");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const rl = @import("raylib");
const rgui = @import("raygui");

pub fn main() anyerror!void {
    const screenWidth = 600;
    const screenHeight = 800;

    rl.setConfigFlags(.{
        .window_undecorated = true,
        .window_unfocused = true,
        .window_resizable = true,
        .window_topmost = false,
    });
    rl.initWindow(screenWidth, screenHeight, "CHONK");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    const alloc_state = std.heap.page_allocator;

    var frame_arena = std.heap.ArenaAllocator.init(alloc_state);
    const frame_arena_alloc = frame_arena.allocator();

    const Page = union(enum) {
        select: struct {
            paths: ?[]lib.TopLevelPath = null,
        },
        viewer: struct {
            path: [:0]const u8,
            fs_store: lib.FS_Store = undefined,
            scroll_state: rl.Vector2 = undefined,
            scroll_view: rl.Rectangle = undefined,
            dbg: struct {
                files_indexed: u64 = 0,
                files_indexed_prev: u64 = 0,
            } = .{},
        },
    };

    var page_current: Page = .{
        .select = .{},
    };

    const font = try rl.getFontDefault();

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // TODO: max water mark
        defer _ = frame_arena.reset(.retain_capacity);

        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        switch (page_current) {
            .select => |*select_data| frame: {
                // FIXME: cache
                // FIXME: ensure no unessecary dupeZ in lib.get_top_level_paths
                select_data.paths = lib.get_top_level_paths(frame_arena_alloc, frame_arena_alloc) catch |err| {
                    std.debug.print("ERROR: Failed to retrieve file paths: {any}\n", .{err});
                    break :frame;
                };
                const window_width = rl.getRenderWidth();

                const label_height: i32 = label: {
                    const label: [*:0]const u8 = "Select Path or Drive to View";
                    const label_font_size = 48;
                    const label_size = rl.measureTextEx(font, label, label_font_size, 0.1);
                    const label_top_pad = 10;

                    rl.drawText(
                        label,
                        @divTrunc(window_width, 2) - @divTrunc(@as(i32, @intFromFloat(label_size.x)), 2),
                        label_top_pad,
                        label_font_size,
                        rl.Color.black,
                    );
                    break :label @as(i32, @intFromFloat(label_size.y)) + label_top_pad + 20;
                };

                const file_paths = select_data.paths.?;

                const window_width_f32: f32 = @floatFromInt(window_width);
                const path_width = window_width_f32 * 0.5;

                const path_x = (window_width_f32 / 2) - (path_width / 2);
                const path_height = 60;
                const path_font_size = 32;

                rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, path_font_size);

                for (file_paths, 0..) |file, i| {
                    const file_path = file.path;
                    const path_y = @as(f32, @floatFromInt(label_height + @as(i32, @intCast((i * path_height))))); // 30 pixels spacing between lines
                    if (rgui.guiButton(.{
                        .x = path_x,
                        .y = path_y,
                        .width = path_width,
                        .height = path_height,
                    }, file_path) != 0) {
                        const page_prev = page_current;
                        const path = try alloc_state.dupeZ(u8, file_path);
                        page_current = .{
                            .viewer = .{
                                .path = path,
                            },
                        };
                        page_current.viewer.fs_store.init(path) catch |err| {
                            std.debug.print("ERROR: failed to init FS_Store: {any}\n", .{err});
                            page_current = page_prev;
                            break :frame;
                        };
                        const thread = Thread.spawn(.{}, lib.index_paths_starting_with, .{ page_current.viewer.path, alloc_state, &page_current.viewer.fs_store, &page_current.viewer.dbg.files_indexed }) catch |err| {
                            std.debug.print("ERROR: failed to spawn worker thread: {any}\n", .{err});
                            // viewer_data.worker_thread_pool_running.reset();
                            // viewer_data.worker_thread_pool.deinit();
                            // try viewer_data.worker_thread_pool_queue.enqueue(dir);
                            page_current = page_prev;
                            break :frame;
                        };
                        thread.detach();
                        break :frame;
                    }
                }
            },
            .viewer => |*viewer_data| frame: {
                const show_dbg_info = true;
                defer if (show_dbg_info) dbg: {
                    const frame_rate = rl.getFPS();
                    const frame_time = rl.getFrameTime();

                    const files_per_second = @as(f64, @floatFromInt(viewer_data.dbg.files_indexed -| viewer_data.dbg.files_indexed_prev)) / frame_time;
                    viewer_data.dbg.files_indexed_prev = viewer_data.dbg.files_indexed;

                    const debug_text_size = 32;

                    rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, debug_text_size);

                    const dbg_text = std.fmt.allocPrintZ(frame_arena_alloc, "FPS={: >4} | FT={: >4}ms | IDX={: >5}/s | FILES={}", .{
                        frame_rate,
                        round_to_decimal_places(frame_time / std.time.ms_per_s, 5),
                        round_to_decimal_places(files_per_second, 5),
                        viewer_data.dbg.files_indexed,
                    }) catch {
                        break :dbg;
                    };
                    rl.drawText(dbg_text, 0, rl.getRenderHeight() - debug_text_size - 5, debug_text_size, rl.Color.black);
                };

                const window_width = rl.getRenderWidth();

                {
                    const back_button_font_size = 32;
                    rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, back_button_font_size);

                    if (rgui.guiButton(.{
                        .x = 5,
                        .y = 5,
                        .width = 40,
                        .height = 40,
                    }, "<") != 0) {
                        page_current = .{ .select = .{
                            .paths = null,
                        } };
                        // tell worker thread to go die
                        break :frame;
                    }
                }

                const label_height: i32 = label: {
                    const label: [*:0]const u8 = viewer_data.path;
                    const label_font_size = 48;
                    const label_size = rl.measureTextEx(font, label, label_font_size, 0.1);
                    const label_top_pad = 10;

                    rl.drawText(
                        label,
                        @divTrunc(window_width, 2) - @divTrunc(@as(i32, @intFromFloat(label_size.x)), 2),
                        label_top_pad,
                        label_font_size,
                        rl.Color.black,
                    );
                    break :label @as(i32, @intFromFloat(label_size.y)) + label_top_pad + 20;
                };

                const dir_entries: []DirEntry = blk: {
                    const store = viewer_data.fs_store;
                    const root = store.root_entry_ptr;
                    if (root.children_count == 0) {
                        break :blk &[_]DirEntry{};
                    }
                    const children = store.entries[root.children_start..][0..root.children_count];
                    const dir_entries = try frame_arena_alloc.alloc(DirEntry, children.len);
                    for (children, dir_entries) |*child, *dir_entry| {
                        if (child.parent != lib.FS_Store.ROOT_ENTRY_INDEX) {
                            // not all init
                            // FIXME: use some space for a checksum (0xdeadbeef) to detect incomplete initialization
                            break :blk &[_]DirEntry{};
                        }
                        dir_entry.* = DirEntry{
                            .name = @ptrCast(child.name[0..child.name_len]),
                            .size_bytes = child.byte_count,
                        };
                    }
                    std.sort.insertion(DirEntry, dir_entries, {}, DirEntry.gt_than);
                    break :blk dir_entries;
                };

                // std.debug.print("FOUND {d} entries\n", .{dir_entries.len});

                const path_font_size = 32;
                const path_height = 60;

                const window_width_f32: f32 = @floatFromInt(window_width);
                const window_height_f32: f32 = @floatFromInt(rl.getRenderHeight());
                const scroll_width = window_width_f32 * 0.8;
                const scroll_height = (window_height_f32 - @as(f32, @floatFromInt(label_height)) - 100) / 2;

                const scroll_bounds = rl.Rectangle{
                    .x = (window_width_f32 / 2) - (scroll_width / 2),
                    .y = @floatFromInt(label_height + 50),
                    .height = scroll_height,
                    .width = scroll_width,
                };
                const scroll_content = rl.Rectangle{
                    .x = 0,
                    .y = 0,
                    .width = scroll_width,
                    .height = @floatFromInt(dir_entries.len * path_height),
                };

                _ = rgui.guiScrollPanel(scroll_bounds, null, scroll_content, &viewer_data.scroll_state, &viewer_data.scroll_view);

                const showScrollBounds = false;
                if (showScrollBounds) {
                    rl.drawRectangleRec(.{
                        .x = scroll_bounds.x + viewer_data.scroll_state.x,
                        .y = scroll_bounds.y + viewer_data.scroll_state.y,
                        .width = scroll_content.width,
                        .height = scroll_content.height,
                    }, rl.Color.fade(rl.Color.gold, 0.1));
                }

                // const path_width = window_width_f32 * 0.5;

                rl.beginScissorMode(
                    @intFromFloat(viewer_data.scroll_view.x),
                    @intFromFloat(viewer_data.scroll_view.y),
                    @intFromFloat(viewer_data.scroll_view.width),
                    @intFromFloat(viewer_data.scroll_view.height),
                );
                const path_x = scroll_bounds.x + 25;

                rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, path_font_size);

                for (dir_entries, 0..) |file, i| {
                    const path_y = scroll_bounds.y + @as(f32, @floatFromInt((i * path_height))) + viewer_data.scroll_state.y; // 30 pixels spacing between lines
                    rl.drawText(
                        file.name,
                        @intFromFloat(path_x),
                        @intFromFloat(path_y),
                        path_font_size,
                        rl.Color.black,
                    );
                    const size_text = fmt_file_size(frame_arena_alloc, file.size_bytes);
                    // std.debug.print("{s} size text {s}\n", .{ file.abs_path, size_text });
                    const size_text_size = rl.measureTextEx(font, size_text, path_font_size, 0);
                    rl.drawText(
                        size_text,
                        @intFromFloat(scroll_bounds.x + scroll_bounds.width - size_text_size.x - 75),
                        @intFromFloat(path_y),
                        path_font_size,
                        rl.Color.black,
                    );
                }
                rl.endScissorMode();

                {
                    const tree_view_rect: rl.Rectangle = .{
                        .x = (window_width_f32 / 2) - (scroll_width / 2),
                        .y = scroll_bounds.y + scroll_bounds.height + 50,
                        .width = scroll_width,
                        .height = window_height_f32 - scroll_bounds.y - scroll_bounds.height - 100,
                    };
                    rl.drawRectangleRec(tree_view_rect, rl.Color.fade(rl.Color.red, 0.1));
                    squarify(frame_arena_alloc, dir_entries, tree_view_rect);
                }
            },
        }
    }
}
const DirEntry = struct {
    name: [:0]const u8,
    size_bytes: u64,

    fn gt_than(_: void, lhs: DirEntry, rhs: DirEntry) bool {
        if (lhs.size_bytes == rhs.size_bytes) {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
        return lhs.size_bytes > rhs.size_bytes;
    }
};

// https://cgl.ethz.ch/teaching/scivis_common/Literature/squarifiedTreeMaps.pdf
// https://github.com/nicopolyptic/treemap/blob/master/src/main/ts/squarifier.ts
fn squarify(alloc: Allocator, dir_entries: []DirEntry, rect: rl.Rectangle) void {
    // TODO: scaleWeights?
    // this.scaleWeights(nodes, width, height);
    std.debug.assert(std.sort.isSorted(DirEntry, dir_entries, {}, DirEntry.gt_than));
    const util = struct {
        fn sum(row: []f32) f32 {
            var sum_: f32 = 0;
            for (row) |d| {
                sum_ += d;
            }
            return sum_;
        }
        fn min(row: []f32) f32 {
            var min_: f32 = std.math.floatMax(f32);
            for (row) |d| {
                min_ = @min(min_, d);
            }
            return min_;
        }
        fn max(row: []f32) f32 {
            var max_: f32 = 0;
            for (row) |d| {
                max_ = @max(max_, d);
            }
            return max_;
        }

        fn worst(s: f32, min_: f32, max_: f32, w: f32) f32 {
            return @max((w * w * max_) / (s * s), (s * s) / (w * w * min_));
        }
    };
    const colors = generate_palette(alloc, dir_entries.len) catch unreachable;

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
    var vertical = rect.height < rect.width;
    var w = if (vertical) rect.height else rect.width;
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
        const s = util.sum(row_weights.items);
        const min = util.min(row_weights.items);
        const max = util.max(row_weights.items);
        const wit = util.worst(s + r, @min(min, r), @max(max, r), w);
        const without = util.worst(s, min, max, w);
        if (row.items.len == 0 or wit < without) {
            row.appendAssumeCapacity(c);
            row_weights.appendAssumeCapacity(r);
            row_colors.appendAssumeCapacity(colors[i]);
            i += 1;
            continue;
        }
        var rx = x;
        var ry = y;
        const z = s / w;
        for (0..row.items.len) |j| {
            const d = row_weights.items[j] / z;
            const color = row_colors.items[j];
            if (vertical) {
                const rec = .{ .x = rx, .y = ry, .width = z, .height = d };
                rl.drawRectangleRec(rec, color);
                rl.drawRectangleLinesEx(rec, 5, rl.Color.light_gray);
                // createRectangle(rx,ry,z,d,row[j]);
                ry = ry + d;
            } else {
                // createRectangle(rx,ry,d,z,row[j]);
                const rec = .{ .x = rx, .y = ry, .width = d, .height = z };
                rl.drawRectangleRec(rec, color);
                rl.drawRectangleLinesEx(rec, 5, rl.Color.light_gray);
                rx = rx + d;
            }
        }
        if (vertical) {
            x = x + z;
            rw = rw - z;
        } else {
            y = y + z;
            rh = rh - z;
        }

        vertical = rh < rw;
        w = if (vertical) rh else rw;
        row.clearRetainingCapacity();
        row_weights.clearRetainingCapacity();
        row_colors.clearRetainingCapacity();
    }
}

fn fmt_file_size(alloc: Allocator, bytes: u64) [:0]const u8 {
    return std.fmt.allocPrintZ(alloc, "{}", .{std.fmt.fmtIntSizeDec(bytes)}) catch "";
}

fn round_to_decimal_places(value: f64, decimal_places: usize) f64 {
    const factor = std.math.pow(f64, 10.0, @floatFromInt(decimal_places));
    return std.math.round(value * factor) / factor;
}

fn hcl_to_rgb(h: f32, c: f32, l: f32) rl.Color {
    const math = std.math;

    const a1 = c * math.cos(h * math.pi / 180);
    const b1 = c * math.sin(h * math.pi / 180);

    const L = (l * 255) / 100;
    const A = a1 + 128;
    const B = b1 + 128;

    var y = (L + 16) / 116;
    var x = y + A / 500;
    var z = y - B / 200;

    x = 0.95047 * (if (x * x * x > 0.008856) x * x * x else (x - 16 / 116) / 7.787);
    y = 1.00000 * (if (y * y * y > 0.008856) y * y * y else (y - 16 / 116) / 7.787);
    z = 1.08883 * (if (z * z * z > 0.008856) z * z * z else (z - 16 / 116) / 7.787);

    var r = x * 3.2406 + y * -1.5372 + z * -0.4986;
    var g = x * -0.9689 + y * 1.8758 + z * 0.0415;
    var b = x * 0.0557 + y * -0.2040 + z * 1.0570;

    r = @floatCast(if (r > 0.0031308) (1.055 * std.math.pow(f64, r, 1.0 / 2.4) - 0.055) else 12.92 * r);
    g = @floatCast(if (g > 0.0031308) (1.055 * std.math.pow(f64, g, 1.0 / 2.4) - 0.055) else 12.92 * g);
    b = @floatCast(if (b > 0.0031308) (1.055 * std.math.pow(f64, b, 1.0 / 2.4) - 0.055) else 12.92 * b);

    const a = 1.0;

    r = @max(0, @min(r, 1.0));
    g = @max(0, @min(g, 1.0));
    b = @max(0, @min(b, 1.0));

    return rl.Color.fromNormalized(.{
        .x = r,
        .y = g,
        .z = b,
        .w = a,
    });
}

fn generate_palette(alloc: Allocator, count_int: usize) ![]rl.Color {
    const palette = try alloc.alloc(rl.Color, count_int);
    const count: f32 = @floatFromInt(count_int);
    const hue_step = 360.0 / count;
    var h: f32 = 0.0;

    for (0..count_int) |i| {
        const c: f32 = 60.0 + @as(f32, @floatFromInt(i)) / (count - 1) * 40.0;
        const l: f32 = 70.0 - @as(f32, @floatFromInt(i)) / (count - 1) * 40.0;
        const color = hcl_to_rgb(h, c, l);
        palette[i] = color;
        h += hue_step;
    }

    return palette;
}
