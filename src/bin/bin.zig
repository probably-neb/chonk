const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const colormaps = @import("colormaps.zig");

const fs_index = @import("fs-index");
const text = @import("text");
const ui = @import("ui");

const rl = @import("raylib");
const rgui = @import("raygui");
const clay = @import("zclay");

const alloc_state = std.heap.page_allocator;
var frame_arena = std.heap.ArenaAllocator.init(alloc_state);
pub const frame_arena_alloc: Allocator = frame_arena.allocator();

var page_current: Page = Page.create_select();
var page_next: ?Page = null;
var entry_next: ?*fs_index.FS_Store.Entry = null;
const screenWidth = 600;
const screenHeight = 800;

var win_dims: clay.Dimensions = .{
    .w = @floatFromInt(screenWidth),
    .h = @floatFromInt(screenHeight),
};

const Page = union(enum) {
    select: struct {
        paths: ?[]fs_index.TopLevelPath = null,
    },
    viewer: struct {
        path: [:0]const u8,
        fs_store: fs_index.FS_Store = undefined,
        entry_cur: *fs_index.FS_Store.Entry = undefined,
        nav_stack: std.ArrayList(*fs_index.FS_Store.Entry) = .empty,
        cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        worker_thread: ?std.Thread = null,
        dbg: struct {
            files_indexed: u64 = 0,
            files_indexed_prev: u64 = 0,
        } = .{},
    },

    const ViewerData = @FieldType(Page, "viewer");
    const SelectData = @FieldType(Page, "select");

    pub fn create_viewer(path: [:0]const u8) Page {
        return .{ .viewer = .{ .path = path } };
    }
    pub fn create_select() Page {
        return .{ .select = .{} };
    }
};

pub fn main() anyerror!void {
    rl.setConfigFlags(.{
        .window_undecorated = true,
        .window_unfocused = true,
        .window_resizable = true,
        .window_topmost = false,
    });
    rl.initWindow(screenWidth, screenHeight, "CHONK");
    defer rl.closeWindow();

    rl.setTargetFPS(60);
    try text.init(alloc_state);

    const clay_min_mem_amount: u32 = clay.minMemorySize();
    const clay_memory = try alloc_state.alloc(u8, clay_min_mem_amount);
    const clay_arena: clay.Arena = clay.createArenaWithCapacityAndMemory(clay_memory);
    _ = clay.initialize(clay_arena, .{ .h = screenHeight, .w = screenWidth }, .{});

    clay.setMeasureTextFunction(void, {}, text.clay_measure_text);

    // Main loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // TODO: max water mark
        defer _ = frame_arena.reset(.retain_capacity);
        if (page_next) |pn| page_swap: {
            defer page_next = null;
            // Signal cancellation and wait for worker thread BEFORE swapping pages,
            // while the pointers the thread holds are still valid
            // Clean up current page BEFORE swapping, while we have mutable access
            switch (page_current) {
                .select => {},
                .viewer => |*viewer_data| {
                    viewer_data.cancelled.store(true, .release);
                    // Wait for the worker thread to finish before invalidating pointers
                    if (viewer_data.worker_thread) |wt| {
                        wt.join();
                        viewer_data.worker_thread = null;
                    }
                    viewer_data.nav_stack.deinit(alloc_state);
                    viewer_data.nav_stack = .empty;
                    viewer_data.fs_store.deinit();
                    alloc_state.free(viewer_data.path);
                },
            }
            const page_prev = page_current;
            page_current = pn;
            switch (pn) {
                .select => {},
                .viewer => {
                    const path = pn.viewer.path;
                    page_current.viewer.fs_store.init(path) catch |err| {
                        std.debug.print("ERROR: failed to init FS_Store: {any}\n", .{err});
                        page_current = page_prev;
                        break :page_swap;
                    };
                    page_current.viewer.entry_cur = page_current.viewer.fs_store.root_entry_ptr;
                    page_current.viewer.nav_stack = .empty;
                    page_current.viewer.nav_stack.append(alloc_state, page_current.viewer.fs_store.root_entry_ptr) catch unreachable;
                    page_current.viewer.worker_thread = Thread.spawn(.{}, fs_index.index_paths_starting_with, .{
                        page_current.viewer.path,
                        alloc_state,
                        &page_current.viewer.fs_store,
                        &page_current.viewer.dbg.files_indexed,
                        &page_current.viewer.cancelled,
                    }) catch |err| {
                        std.debug.print("ERROR: failed to spawn worker thread: {any}\n", .{err});
                        // viewer_data.worker_thread_pool_running.reset();
                        // viewer_data.worker_thread_pool.deinit();
                        // try viewer_data.worker_thread_pool_queue.enqueue(dir);
                        page_current = page_prev;
                        break :page_swap;
                    };
                },
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        win_dims = .{
            .w = @floatFromInt(rl.getRenderWidth()),
            .h = @floatFromInt(rl.getRenderHeight()),
        };

        clay.setLayoutDimensions(win_dims);
        const pointer_pos = rl.getMousePosition();
        clay.setPointerState(
            .{
                .x = pointer_pos.x,
                .y = pointer_pos.y,
            },
            rl.isMouseButtonDown(.left),
        );

        const scroll_delta = rl.getMouseWheelMoveV();
        clay.updateScrollContainers(true, .{
            .x = scroll_delta.x * 4,
            .y = scroll_delta.y * 4,
        }, rl.getFrameTime());

        rl.clearBackground(rl.Color.white);

        clay.beginLayout();

        switch (page_current) {
            .select => |*select_data| {
                try render_select(select_data);
            },
            .viewer => |*viewer_data| {
                try render_viewer(viewer_data);
            },
        }

        try ui.draw();

        const show_dbg_info = true;
        if (show_dbg_info) dbg: {
            const frame_rate = rl.getFPS();
            const frame_time = rl.getFrameTime();

            const files_per_second, const files_total = switch (page_current) {
                .viewer => |*viewer_data| fps: {
                    const files_per_second = @as(f64, @floatFromInt(viewer_data.dbg.files_indexed -| viewer_data.dbg.files_indexed_prev)) / frame_time;
                    viewer_data.dbg.files_indexed_prev = viewer_data.dbg.files_indexed;

                    break :fps .{ files_per_second, viewer_data.dbg.files_indexed };
                },
                .select => .{ 0, 0 },
            };

            const debug_text_size = 32;

            rgui.setStyle(.default, .{ .default = .text_size }, debug_text_size);

            const dbg_text = std.fmt.allocPrintSentinel(frame_arena_alloc, "FPS={: >4} | FT={: >4}ms | FILES={} | IDX={: >5}/s", .{
                frame_rate,
                round_to_decimal_places(frame_time / std.time.ms_per_s, 5),
                files_total,
                round_to_decimal_places(files_per_second, 5),
            }, 0) catch {
                break :dbg;
            };
            rl.drawText(dbg_text, 0, rl.getRenderHeight() - debug_text_size - 5, debug_text_size, rl.Color.black);
        }
    }
}

fn render_select(select_data: *Page.SelectData) !void {
    // FIXME: cache
    // FIXME: ensure no unessecary dupeZ in lib.get_top_level_paths
    select_data.paths = fs_index.get_top_level_paths(frame_arena_alloc, frame_arena_alloc) catch |err| err: {
        std.debug.print("ERROR: Failed to retrieve file paths: {any}\n", .{err});
        break :err &.{};
    };
    clay.UI()(.{
        .id = .ID("Page_Select"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .h = clay.SizingAxis.grow, .w = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .center, .y = .top },
            .child_gap = 32,
        },
    })({
        clay.UI()(.{
            .id = .ID("Select_Title"),
            .layout = .{
                .padding = .all(16),
                .sizing = .{ .w = .fit, .h = .fit },
            },
        })({
            clay.text("Select Path or Drive to View", .{
                .font_size = 48,
                .letter_spacing = 4,
            });
        });
        clay.UI()(.{
            .id = clay.ElementId.ID("Select_Paths"),
            .layout = .{
                .direction = .top_to_bottom,
                .child_alignment = .{ .x = .left, .y = .top },
                .sizing = .{
                    .w = clay.SizingAxis.percent(0.6),
                    .h = clay.SizingAxis.fit,
                },
                .padding = clay.Padding.all(8),
                .child_gap = 16,
            },
        })({
            for (select_data.paths.?, 0..) |path, index| {
                render_select_entry(path, index);
            }
        });
    });
}

fn render_select_entry(path: fs_index.TopLevelPath, index: usize) void {
    const top_level_path_id = clay.ElementId.IDI("TopLevelPath", @intCast(index));
    clay.UI()(.{
        .id = top_level_path_id,
        .layout = .{
            .direction = .left_to_right,
            .padding = clay.Padding.all(16),
            .sizing = .{
                .w = clay.SizingAxis.grow,
                .h = clay.SizingAxis.grow,
            },
        },
        .border = clay_border_all(
            ui.rl_color_to_arr(rl.Color.light_gray.brightness(0.25)),
            3,
            3.0,
        ),
        .background_color = if (is_hovered(top_level_path_id)) ui.rl_color_to_arr(rl.Color.gray.brightness(0.8)) else .{ 0, 0, 0, 0 },
    })({
        if (is_clicked(top_level_path_id)) {
            std.debug.print("Clicked: {s}\n", .{path.path});
            page_next = Page.create_viewer(alloc_state.dupeZ(u8, path.path) catch unreachable);
        }
        clay.UI()(.{
            .layout = .{
                .direction = .top_to_bottom,
                .child_gap = 8,
                .child_alignment = .{
                    .x = .left,
                    .y = .center,
                },
            },
        })({
            clay.text(path.path, .{
                .color = ui.rl_color_to_arr(rl.Color.black),
                .letter_spacing = 2,
                .font_size = 32,
            });
            if (path.device) |device| {
                clay.text(device, .{
                    .color = ui.rl_color_to_arr(rl.Color.black.brightness(0.5)),
                    .letter_spacing = 2,
                    .font_size = 24,
                });
            }
        });
    });
}

fn render_viewer(viewer_data: *Page.ViewerData) !void {
    if (entry_next) |entry_next_ptr| {
        viewer_data.entry_cur = entry_next_ptr;
        entry_next = null;
    }
    const dir_entries: []DirEntry = blk: {
        const store = viewer_data.fs_store;
        const entry_cur = viewer_data.entry_cur;
        if (entry_cur.children_count == 0 or @atomicLoad(u8, &entry_cur.lock_this, .acquire) != 0) {
            break :blk &[_]DirEntry{};
        }
        const children = store.entries[entry_cur.children_start..][0..entry_cur.children_count];
        const dir_entries = try frame_arena_alloc.alloc(DirEntry, children.len);
        for (children, dir_entries) |*child, *dir_entry| {
            dir_entry.* = DirEntry{
                .name = @ptrCast(child.name[0..child.name_len]),
                .size_bytes = child.byte_count,
                .fs_store_entry_ptr = child,
            };
        }
        std.sort.heap(DirEntry, dir_entries, {}, DirEntry.gt_than);
        break :blk dir_entries;
    };

    const page_select_id = clay.ElementId.ID("Page_Select");
    clay.UI()(.{
        .id = page_select_id,
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .h = clay.SizingAxis.grow, .w = clay.SizingAxis.grow },
            .child_alignment = .{ .x = .center, .y = .top },
            .child_gap = 32,
            .padding = clay.Padding.all(16),
        },
    })({
        render_top_bar(viewer_data);
        render_dir_entries(viewer_data, dir_entries);
    });
}

fn render_dir_entries(viewer_data: *Page.ViewerData, dir_entries: []DirEntry) void {
    const orientation: clay.LayoutDirection = if (win_dims.w > win_dims.h) .left_to_right else .top_to_bottom;
    const dir_entry_row_height: f32 = 56;
    const dir_entry_overscan_rows: usize = 4;

    clay.UI()(.{
        .layout = .{
            .direction = orientation,
            .child_gap = 48,
            .child_alignment = .{
                .x = .center,
                .y = .center,
            },
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
            .padding = clay.Padding.all(32),
        },
    })({
        const scroll_container_id: clay.ElementId = .ID("Viewer_Dir_Entries_Scroll");
        var scroll_data = clay.getScrollContainerData(scroll_container_id);
        if (!scroll_data.found) {
            var zero = clay.Vector2{ .x = 0, .y = 0 };
            scroll_data.scroll_position = &zero;
        }

        const child_sizing = switch (orientation) {
            .top_to_bottom => clay.Sizing{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.percent(0.5) },
            .left_to_right => clay.Sizing{ .w = clay.SizingAxis.percent(0.5), .h = clay.SizingAxis.grow },
        };

        const list_height = if (scroll_data.found) scroll_data.content_dimensions.h else switch (orientation) {
            .top_to_bottom => (win_dims.h - 64.0 - 48.0) * 0.5,
            .left_to_right => win_dims.h - 64.0,
        };
        const viewport_height = if (scroll_data.found) scroll_data.scroll_container_dimensions.h else @max(0.0, list_height - 32.0);
        const scroll_offset_y = @max(0.0, -scroll_data.scroll_position.y);

        const total_rows = dir_entries.len;
        const visible_rows = if (viewport_height > 0) @as(usize, @intFromFloat(@ceil(viewport_height / dir_entry_row_height))) else total_rows;
        const first_visible_row: usize = @intFromFloat(@floor(scroll_offset_y / dir_entry_row_height));
        const start_index = first_visible_row -| dir_entry_overscan_rows;
        const end_index = @min(total_rows, first_visible_row + visible_rows + dir_entry_overscan_rows);

        const top_spacer_height = @as(f32, @floatFromInt(start_index)) * dir_entry_row_height;
        const bottom_spacer_height = @as(f32, @floatFromInt(total_rows - end_index)) * dir_entry_row_height;

        clay.UI()(.{
            .id = scroll_container_id,
            .layout = .{
                .sizing = child_sizing,
                .direction = .top_to_bottom,
                .padding = clay.Padding.axes(16, 8),
            },
            .border = border: {
                const color = ui.rl_color_to_arr(rl.Color.gray.brightness(0.8));
                var config = clay_border_all(color, 4, 8);
                config.width.between_children = 3;
                break :border config;
            },
            .clip = .{
                .vertical = true,
                .child_offset = scroll_data.scroll_position.*,
            },
        })({
            if (top_spacer_height > 0) {
                clay.UI()(.{ .layout = .{ .sizing = .{ .h = .fixed(top_spacer_height), .w = .grow } } })({});
            }

            for (dir_entries[start_index..end_index], start_index..) |entry, index| {
                render_dir_entry(viewer_data, entry, index);
            }

            if (bottom_spacer_height > 0) {
                clay.UI()(.{ .layout = .{ .sizing = .{ .h = .fixed(bottom_spacer_height), .w = .grow } } })({});
            }
        });

        const dir_entries_data = frame_arena_alloc.create(ui.ClayCustom) catch {
            std.debug.print("ERROR: failed to allocate ClayCustom in frame arena\n", .{});
            return;
        };
        dir_entries_data.* = .{ .squarified_treemap = .{
            .dir_entries = dir_entries,
        } };
        clay.UI()(.{
            .layout = .{
                .sizing = child_sizing,
            },
            .background_color = ui.rl_color_to_arr(rl.Color.gray.brightness(0.5)),
            .custom = .{
                .custom_data = @ptrCast(@constCast(dir_entries_data)),
            },
        })({});
    });
}

fn render_dir_entry(viewer_data: *Page.ViewerData, entry: DirEntry, index: usize) void {
    clay.UI()(.{
        .id = clay.ElementId.IDI("DirEntry", @intCast(index)),
        .layout = .{
            .padding = clay.Padding.all(8),
            .direction = .left_to_right,
            .child_alignment = .{ .y = .center },
            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.fixed(56) },
        },
    })({
        clay.text(entry.name, .{
            .font_size = 24,
            .letter_spacing = 4,
        });

        clay.UI()(.{
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.grow },
            },
        })({});

        const size_str = fmt_file_size(frame_arena_alloc, entry.size_bytes);
        clay.text(size_str, .{ .letter_spacing = 4, .wrap_mode = .none });
        clay.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(20) } } })({});

        const nav_button_id = clay.ElementId.IDI("Dir_Entry_Nav_Button", @intCast(index));

        clay.UI()(.{
            .id = nav_button_id,
            .layout = .{
                .sizing = .{ .w = .percent(0.10), .h = .grow },
                .child_alignment = .{ .x = .center },
                .padding = clay.Padding.axes(4, 8),
            },
            .background_color = ui.rl_color_to_arr(rl.Color.sky_blue),
            .corner_radius = clay.CornerRadius.all(4),
        })({
            if (is_clicked(nav_button_id)) {
                entry_next = entry.fs_store_entry_ptr;
                viewer_data.nav_stack.append(alloc_state, entry.fs_store_entry_ptr) catch |err| {
                    std.debug.print("ERROR: failed to append nav stack entry: {any}\n", .{err});
                };
            }
            clay.text("->", .{ .letter_spacing = 4 });
        });
    });
}

fn render_top_bar(viewer_data: *Page.ViewerData) void {
    clay.UI()(.{
        .layout = .{
            .direction = .left_to_right,
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 8,
            .sizing = .{ .w = clay.SizingAxis.grow },
            .padding = clay.Padding.axes(0, 56),
        },
    })({
        const back_button_id = clay.ElementId.ID("Viewer_Back_Btn");
        clay.UI()(.{
            .id = back_button_id,
            .layout = .{
                .sizing = .{ .w = clay.SizingAxis.fixed(36), .h = clay.SizingAxis.fixed(36) },
                .padding = clay.Padding.all(4),
                .child_alignment = .{
                    .x = .center,
                    .y = .center,
                },
            },
            .background_color = ui.rl_color_to_arr(rl.Color.gray.brightness(if (is_hovered(back_button_id)) 0.9 else 0.8)),
            .corner_radius = clay.CornerRadius.all(1.0),
        })({
            if (is_hovered(back_button_id) and rl.isMouseButtonPressed(.left)) {
                page_next = Page.create_select();
            }
            clay.text("<", .{
                .font_size = 32,
            });
        });
        render_breadcrumbs(viewer_data);
    });
}

fn render_breadcrumbs(viewer_data: *Page.ViewerData) void {
    for (viewer_data.nav_stack.items, 0..) |crumb_entry, crumb_render_idx| {
        const crumb_is_current = crumb_entry == viewer_data.entry_cur;
        const crumb_is_root = crumb_entry == viewer_data.fs_store.root_entry_ptr;
        const crumb_button_id = clay.ElementId.IDI("Breadcrumb_Item", @intCast(crumb_render_idx));

        clay.UI()(.{
            .id = crumb_button_id,
            .layout = .{
                .child_gap = 8,
                .padding = clay.Padding.axes(4, 6),
            },
            .background_color = if (is_hovered(crumb_button_id) and !crumb_is_current) ui.rl_color_to_arr(rl.Color.gray.brightness(0.92)) else .{ 0, 0, 0, 0 },
            .corner_radius = clay.CornerRadius.all(3),
        })({
            if (is_hovered(crumb_button_id) and rl.isMouseButtonPressed(.left) and !crumb_is_current) {
                viewer_data.entry_cur = crumb_entry;
                while (viewer_data.nav_stack.items.len > 0 and viewer_data.nav_stack.items[viewer_data.nav_stack.items.len - 1] != crumb_entry) {
                    _ = viewer_data.nav_stack.pop();
                }
            }
            const crumb_name = if (crumb_is_root) viewer_data.path else crumb_entry.name[0..crumb_entry.name_len];

            clay.text(crumb_name, .{
                .letter_spacing = 2,
                .font_size = 26,
                .color = ui.rl_color_to_arr(rl.Color.black.brightness(if (crumb_is_current) 0.4 else 0.2)),
            });
            if (!std.mem.endsWith(u8, crumb_name, "/")) {
                clay.text("/", .{
                    .letter_spacing = 2,
                    .font_size = 26,
                    .color = ui.rl_color_to_arr(rl.Color.black.brightness(if (crumb_is_current) 0.4 else 0.2)),
                });
            }
        });
    }
}

fn is_clicked(id: clay.ElementId) bool {
    return is_hovered(id) and rl.isMouseButtonPressed(.left);
}

fn is_hovered(id: clay.ElementId) bool {
    return clay.pointerOver(id);
}

pub const DirEntry = struct {
    name: [:0]const u8,
    size_bytes: u64,
    fs_store_entry_ptr: *fs_index.FS_Store.Entry,

    fn gt_than(_: void, lhs: DirEntry, rhs: DirEntry) bool {
        return lhs.size_bytes > rhs.size_bytes or
            (lhs.size_bytes == rhs.size_bytes and std.mem.lessThan(u8, lhs.name, rhs.name));
    }
};

// https://cgl.ethz.ch/teaching/scivis_common/Literature/squarifiedTreeMaps.pdf
// https://github.com/nicopolyptic/treemap/blob/master/src/main/ts/squarifier.ts

fn fmt_file_size(alloc: Allocator, bytes: u64) [:0]const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1000.0 and unit_idx < units.len - 1) {
        size /= 1000.0;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.allocPrintSentinel(alloc, "{d} {s}", .{ bytes, units[0] }, 0) catch "";
    } else {
        return std.fmt.allocPrintSentinel(alloc, "{d:.1} {s}", .{ size, units[unit_idx] }, 0) catch "";
    }
}

fn round_to_decimal_places(value: f64, decimal_places: usize) f64 {
    const factor = std.math.pow(f64, 10.0, @floatFromInt(decimal_places));
    return std.math.round(value * factor) / factor;
}

fn pad(original: rl.Rectangle, padding: rl.Vector2) rl.Rectangle {
    var rect = original;
    rect.x += padding.x;
    rect.width -= padding.x * 2;
    rect.y += padding.y;
    rect.height -= padding.y * 2;
    return rect;
}

fn divide_in_2_with_padding(rect: rl.Rectangle, padding: f32) struct { rl.Rectangle, rl.Rectangle } {
    const vertical = rect.height > rect.width;
    var left = rect;
    var right = rect;
    if (vertical) {
        left.height /= 2;
        right.y += left.height;
        right.height = left.height;
        left.height -= padding;
        right.y += padding;
        right.height -= padding;
    } else {
        left.width /= 2;
        right.x += left.width;
        right.width = left.width;
        left.width -= padding;
        right.x += padding;
        right.width -= padding;
    }
    return .{ left, right };
}

fn clay_border_all(color: clay.Color, width: u16, _: f32) clay.BorderElementConfig {
    return clay.BorderElementConfig{
        .color = color,
        .width = clay.BorderWidth.outside(width),
    };
}
