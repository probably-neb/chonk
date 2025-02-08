const std = @import("std");
const lib = @import("root.zig");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const colormaps = @import("colormaps.zig");

const rl = @import("raylib");
const rgui = @import("raygui");
const clay = @import("zclay");

const FONT_COUNT = 1;
var fonts: [FONT_COUNT]rl.Font = undefined;

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

    fonts[0] = try rl.getFontDefault();

    const clay_min_mem_amount: u32 = clay.minMemorySize();
    const clay_memory = try alloc_state.alloc(u8, clay_min_mem_amount);
    const clay_arena: clay.Arena = clay.createArenaWithCapacityAndMemory(clay_memory);
    _ = clay.initialize(clay_arena, .{ .h = screenHeight, .w = screenWidth }, .{});

    clay.setMeasureTextFunction(clay_measure_text);

    var frame_arena = std.heap.ArenaAllocator.init(alloc_state);
    const frame_arena_alloc = frame_arena.allocator();

    const Page = union(enum) {
        select: struct {
            paths: ?[]lib.TopLevelPath = null,
        },
        viewer: struct {
            path: [:0]const u8,
            fs_store: lib.FS_Store = undefined,
            entry_cur: *lib.FS_Store.Entry = undefined,
            scroll_state: rl.Vector2 = undefined,
            scroll_view: rl.Rectangle = undefined,
            dbg: struct {
                files_indexed: u64 = 0,
                files_indexed_prev: u64 = 0,
            } = .{},
        },

        const Page = @This();

        pub fn create_viewer(path: [:0]const u8) Page {
            return .{ .viewer = .{ .path = path } };
        }
        pub fn create_select() Page {
            return .{ .select = .{} };
        }
    };

    var page_current: Page = Page.create_select();

    var page_next: ?Page = null;

    var entry_next: ?*lib.FS_Store.Entry = null;

    // Main loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // TODO: max water mark
        defer _ = frame_arena.reset(.retain_capacity);
        if (page_next) |pn| page_swap: {
            defer page_next = null;
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
                    const thread = Thread.spawn(.{}, lib.index_paths_starting_with, .{
                        page_current.viewer.path,
                        alloc_state,
                        &page_current.viewer.fs_store,
                        &page_current.viewer.dbg.files_indexed,
                    }) catch |err| {
                        std.debug.print("ERROR: failed to spawn worker thread: {any}\n", .{err});
                        // viewer_data.worker_thread_pool_running.reset();
                        // viewer_data.worker_thread_pool.deinit();
                        // try viewer_data.worker_thread_pool_queue.enqueue(dir);
                        page_current = page_prev;
                        break :page_swap;
                    };
                    thread.detach();
                },
            }
            switch (page_prev) {
                .select => {},
                .viewer => |viewer_data| {
                    alloc_state.free(viewer_data.path);
                    // TODO: deinit fs_store? and kill thread
                },
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();

        const win_dims: clay.Dimensions = .{
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
            .x = scroll_delta.x,
            .y = scroll_delta.y,
        }, rl.getFrameTime());

        rl.clearBackground(rl.Color.white);

        clay.beginLayout();

        switch (page_current) {
            .select => |*select_data| {
                // FIXME: cache
                // FIXME: ensure no unessecary dupeZ in lib.get_top_level_paths
                select_data.paths = lib.get_top_level_paths(frame_arena_alloc, frame_arena_alloc) catch |err| err: {
                    std.debug.print("ERROR: Failed to retrieve file paths: {any}\n", .{err});
                    break :err &.{};
                };
                clay.UI(&.{
                    clay.Config.ID("Page_Select"),
                    clay.Config.layout(.{
                        .direction = .TOP_TO_BOTTOM,
                        .sizing = .{ .h = clay.SizingAxis.grow, .w = clay.SizingAxis.grow },
                        .child_alignment = .{ .x = .CENTER, .y = .TOP },
                        .child_gap = 32,
                    }),
                })({
                    clay.UI(&.{
                        clay.Config.ID("Select_Title"), clay.Config.layout(.{
                            .padding = clay.Padding.all(16),
                            .sizing = .{ .w = clay.SizingAxis.fit, .h = clay.SizingAxis.fit },
                        }),
                    })({
                        clay.text("Select Path or Drive to View", clay.Config.text(.{
                            .font_size = 48,
                            .letter_spacing = 4,
                        }));
                    });
                    clay.UI(&.{
                        clay.Config.ID("Select_Paths"),
                        clay.Config.layout(.{
                            .direction = .TOP_TO_BOTTOM,
                            .child_alignment = .{ .x = .LEFT, .y = .TOP },
                            .sizing = .{
                                .w = clay.SizingAxis.percent(0.6),
                                .h = clay.SizingAxis.fit,
                            },
                            .padding = clay.Padding.all(8),
                            .child_gap = 16,
                        }),
                    })({
                        for (select_data.paths.?, 0..) |path, index| {
                            clay.UI(&.{
                                clay.Config.IDI("TopLevelPath", @intCast(index)),
                                clay.Config.layout(.{
                                    .direction = .LEFT_TO_RIGHT,
                                    .padding = clay.Padding.all(16),
                                    .sizing = .{
                                        .w = clay.SizingAxis.grow,
                                        .h = clay.SizingAxis.grow,
                                    },
                                }),
                                clay.Config.border(clay_border_all(
                                    rl_color_to_arr(rl.Color.light_gray.brightness(0.25)),
                                    3,
                                    3.0,
                                )),
                                if (clay.pointerOver(clay.IDI("TopLevelPath", @intCast(index)))) clay.Config.rectangle(.{
                                    .color = rl_color_to_arr(rl.Color.gray.brightness(0.8)),
                                }) else ClayCustom.none(),
                            })({
                                if (clay.pointerOver(clay.IDI("TopLevelPath", @intCast(index))) and rl.isMouseButtonPressed(.left)) {
                                    std.debug.print("Clicked: {s}\n", .{path.path});
                                    page_next = Page.create_viewer(alloc_state.dupeZ(u8, path.path) catch unreachable);
                                }
                                clay.UI(&.{
                                    clay.Config.layout(.{
                                        .direction = .TOP_TO_BOTTOM,
                                        .child_gap = 8,
                                        .child_alignment = .{
                                            .x = .LEFT,
                                            .y = .CENTER,
                                        },
                                    }),
                                })({
                                    clay.text(path.path, clay.Config.text(.{
                                        .color = rl_color_to_arr(rl.Color.black),
                                        .letter_spacing = 2,
                                        .font_size = 32,
                                    }));
                                    if (path.device) |device| {
                                        clay.text(device, clay.Config.text(.{
                                            .color = rl_color_to_arr(rl.Color.black.brightness(0.5)),
                                            .letter_spacing = 2,
                                            .font_size = 24,
                                        }));
                                    }
                                });
                            });
                        }
                    });
                });
            },
            .viewer => |*viewer_data| {
                if (entry_next) |entry_next_ptr| {
                    viewer_data.entry_cur = entry_next_ptr;
                    entry_next = null;
                }
                const dir_entries: []DirEntry = blk: {
                    const store = viewer_data.fs_store;
                    const entry_cur = viewer_data.entry_cur;
                    if (entry_cur.children_count == 0) {
                        break :blk &[_]DirEntry{};
                    }
                    const children = store.entries[entry_cur.children_start..][0..entry_cur.children_count];
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
                            .fs_store_entry_ptr = child,
                        };
                    }
                    std.sort.insertion(DirEntry, dir_entries, {}, DirEntry.gt_than);
                    break :blk dir_entries;
                };

                clay.UI(&.{
                    clay.Config.ID("Page_Select"),
                    clay.Config.layout(.{
                        .direction = .TOP_TO_BOTTOM,
                        .sizing = .{ .h = clay.SizingAxis.grow, .w = clay.SizingAxis.grow },
                        .child_alignment = .{ .x = .CENTER, .y = .TOP },
                        .child_gap = 32,
                        .padding = clay.Padding.all(16),
                    }),
                })({
                    {
                        const parent_page_elem_id = clay.getElementId("Page_Select");
                        const back_button_id = clay.Config.ID("Viewer_Back_Btn");
                        clay.UI(&.{
                            back_button_id,
                            clay.Config.floating(.{
                                .offset = .{
                                    .x = 16,
                                    .y = 16,
                                },
                                .zIndex = 1,
                                .expand = .{ .h = 0, .w = 0 },
                                .pointerCaptureMode = .CAPTURE,
                                .parentId = parent_page_elem_id.id,
                                .attachment = .{
                                    .element = .LEFT_TOP,
                                    .parent = .LEFT_TOP,
                                },
                            }),
                            clay.Config.layout(.{
                                .sizing = .{ .w = clay.SizingAxis.fixed(36), .h = clay.SizingAxis.fixed(36) },
                                .padding = clay.Padding.all(4),
                                .child_alignment = .{
                                    .x = .CENTER,
                                    .y = .CENTER,
                                },
                            }),
                            clay.Config.rectangle(.{
                                .color = rl_color_to_arr(rl.Color.gray.brightness(if (clay.pointerOver(back_button_id.id)) 0.9 else 0.8)),
                                .corner_radius = clay.CornerRadius.all(1.0),
                            }),
                        })({
                            if (clay.pointerOver(back_button_id.id) and rl.isMouseButtonPressed(.left)) {
                                page_next = Page.create_select();
                            }
                            clay.text("<", clay.Config.text(.{
                                .font_size = 32,
                            }));
                        });
                    }
                    // TODO: breadcrumbs...
                    clay.text(viewer_data.path, clay.Config.text(.{
                        .letter_spacing = 4,
                        .font_size = 48,
                    }));
                    clay.UI(&.{
                        clay.Config.layout(.{
                            .direction = if (win_dims.w > win_dims.h) .LEFT_TO_RIGHT else .TOP_TO_BOTTOM,
                            .child_gap = 48,
                            .child_alignment = .{
                                .x = .CENTER,
                                .y = .CENTER,
                            },
                            .sizing = .{ .w = clay.SizingAxis.grow, .h = clay.SizingAxis.grow },
                            .padding = clay.Padding.all(32),
                        }),
                    })({
                        const child_sizing: clay.Sizing = if (win_dims.w < win_dims.h) .{
                            .w = clay.SizingAxis.grow,
                            .h = clay.SizingAxis.percent(0.5),
                        } else .{
                            .w = clay.SizingAxis.percent(0.5),
                            .h = clay.SizingAxis.grow,
                        };
                        clay.UI(&.{
                            clay.Config.layout(.{
                                .sizing = child_sizing,
                                .direction = .TOP_TO_BOTTOM,
                                .padding = .{
                                    .x = 8,
                                    .y = 16,
                                },
                            }),
                            clay.Config.border(border: {
                                const color = rl_color_to_arr(rl.Color.gray.brightness(0.8));
                                var config = clay_border_all(color, 4, 8);
                                config.between_children = .{
                                    .width = 3,
                                    .color = color,
                                };
                                break :border config;
                            }),
                            clay.Config.scroll(.{
                                .vertical = true,
                            }),
                        })({
                            for (dir_entries, 0..) |entry, index| {
                                clay.UI(&.{
                                    clay.Config.IDI("DirEntry", @intCast(index)),
                                    clay.Config.layout(.{
                                        .padding = clay.Padding.all(8),
                                        .direction = .LEFT_TO_RIGHT,
                                        .child_alignment = .{ .y = .CENTER },
                                        .sizing = .{ .w = clay.SizingAxis.grow },
                                    }),
                                })({
                                    clay.text(entry.name, clay.Config.text(.{
                                        .font_size = 24,
                                        .letter_spacing = 4,
                                    }));

                                    clay.UI(&.{
                                        clay.Config.layout(.{
                                            .sizing = .{ .w = clay.SizingAxis.grow },
                                        }),
                                    })({});

                                    const size_str = fmt_file_size(frame_arena_alloc, entry.size_bytes);
                                    clay.text(size_str, clay.Config.text(.{ .letter_spacing = 4, .wrap_mode = .none }));
                                    clay.UI(&.{clay.Config.layout(.{ .sizing = .{ .w = clay.SizingAxis.fixed(20) } })})({});

                                    const nav_button_id = clay.Config.IDI("Dir_Entry_Nav_Button", @intCast(index));

                                    clay.UI(&.{
                                        nav_button_id,
                                        clay.Config.layout(.{
                                            .sizing = .{ .w = clay.SizingAxis.percent(0.10), .h = clay.SizingAxis.grow },
                                            .child_alignment = .{ .x = .CENTER },
                                            .padding = .{ .x = 8, .y = 4 },
                                        }),
                                        clay.Config.rectangle(.{
                                            .color = rl_color_to_arr(rl.Color.sky_blue),
                                            .corner_radius = clay.CornerRadius.all(4),
                                        }),
                                    })({
                                        if (clay.pointerOver(nav_button_id.id) and rl.isMouseButtonDown(.left)) {
                                            entry_next = entry.fs_store_entry_ptr;
                                        }
                                        clay.text("->", clay.Config.text(.{ .letter_spacing = 4 }));
                                    });
                                });
                            }
                        });
                        const dir_entries_data: ClayCustom = .{ .squarified_treemap = .{
                            .dir_entries = dir_entries,
                        } };
                        clay.UI(&.{
                            clay.Config.layout(.{
                                .sizing = child_sizing,
                            }),
                            clay.Config.rectangle(.{
                                .color = rl_color_to_arr(rl.Color.gray.brightness(0.5)),
                            }),
                            clay.Config.custom(.{
                                .custom_data = @ptrCast(@constCast(&dir_entries_data)),
                            }),
                        })({});
                    });
                });

                // {
                //     const back_button_font_size = 32;
                //     rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, back_button_font_size);
                //
                //     if (rgui.guiButton(.{
                //         .x = 5,
                //         .y = 5,
                //         .width = 40,
                //         .height = 40,
                //     }, "<") != 0) {
                //         page_current = .{ .select = .{
                //             .paths = null,
                //         } };
                //         break :frame;
                //     }
                // }
                //
                // const label_height: i32 = label: {
                //     const label: [*:0]const u8 = viewer_data.path;
                //     const label_font_size = 48;
                //     const label_size = rl.measureTextEx(font_default, label, label_font_size, 0.1);
                //     const label_top_pad = 10;
                //
                //     rl.drawText(
                //         label,
                //         @divTrunc(window_width, 2) - @divTrunc(@as(i32, @intFromFloat(label_size.x)), 2),
                //         label_top_pad,
                //         label_font_size,
                //         rl.Color.black,
                //     );
                //     break :label @as(i32, @intFromFloat(label_size.y)) + label_top_pad + 20;
                // };
                //
                // const window_width_f32: f32 = @floatFromInt(window_width);
                // const window_height_f32: f32 = @floatFromInt(rl.getRenderHeight());
                //
                // const content_rect: rl.Rectangle = pad(.{
                //     .x = 0,
                //     .y = @floatFromInt(label_height),
                //     .width = window_width_f32,
                //     .height = window_height_f32 - @as(f32, @floatFromInt(label_height)),
                // }, .{ .x = 50, .y = 25 });
                // const scroll_rect, const tree_view_rect = divide_in_2_with_padding(
                //     content_rect,
                //     25,
                // );
                // // std.debug.print("FOUND {d} entries\n", .{dir_entries.len});
                //
                // const path_font_size = 32;
                // const path_height = 60;
                //
                // const scroll_content = rl.Rectangle{
                //     .x = 0,
                //     .y = 0,
                //     .width = scroll_rect.width,
                //     .height = @floatFromInt(dir_entries.len * path_height),
                // };
                //
                // _ = rgui.guiScrollPanel(scroll_rect, null, scroll_content, &viewer_data.scroll_state, &viewer_data.scroll_view);
                //
                // const showScrollBounds = false;
                // if (showScrollBounds) {
                //     rl.drawRectangleRec(.{
                //         .x = scroll_rect.x + viewer_data.scroll_state.x,
                //         .y = scroll_rect.y + viewer_data.scroll_state.y,
                //         .width = scroll_content.width,
                //         .height = scroll_content.height,
                //     }, rl.Color.fade(rl.Color.gold, 0.1));
                // }
                //
                // // const path_width = window_width_f32 * 0.5;
                //
                // rl.beginScissorMode(
                //     @intFromFloat(viewer_data.scroll_view.x),
                //     @intFromFloat(viewer_data.scroll_view.y),
                //     @intFromFloat(viewer_data.scroll_view.width),
                //     @intFromFloat(viewer_data.scroll_view.height),
                // );
                // const path_x = scroll_rect.x + 25;
                //
                // rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, path_font_size);
                //
                // for (dir_entries, 0..) |file, i| {
                //     const path_y = scroll_rect.y + @as(f32, @floatFromInt((i * path_height))) + viewer_data.scroll_state.y; // 30 pixels spacing between lines
                //     rl.drawText(
                //         file.name,
                //         @intFromFloat(path_x),
                //         @intFromFloat(path_y),
                //         path_font_size,
                //         rl.Color.black,
                //     );
                //     const size_text = fmt_file_size(frame_arena_alloc, file.size_bytes);
                //     // std.debug.print("{s} size text {s}\n", .{ file.abs_path, size_text });
                //     const size_text_size = rl.measureTextEx(font_default, size_text, path_font_size, 0);
                //     rl.drawText(
                //         size_text,
                //         @intFromFloat(scroll_rect.x + scroll_rect.width - size_text_size.x - 75),
                //         @intFromFloat(path_y),
                //         path_font_size,
                //         rl.Color.black,
                //     );
                // }
                // rl.endScissorMode();
                //
                // squarify(frame_arena_alloc, dir_entries, tree_view_rect);
            },
        }

        var ui_draw_commands: clay.ClayArray(clay.RenderCommand) = clay.endLayout();

        for (0..ui_draw_commands.length) |i| {
            const render_command = clay.renderCommandArrayGet(&ui_draw_commands, @intCast(i));
            const render_text = render_command.text.chars[0..@abs(render_command.text.length)];
            const bounding_box = render_command.bounding_box;
            const rec = .{
                .x = bounding_box.x,
                .y = bounding_box.y,
                .width = bounding_box.width,
                .height = bounding_box.height,
            };
            switch (render_command.command_type) {
                .none => {},
                .text => {
                    const config = render_command.config.text_config;
                    const font = fonts[config.font_id];

                    rl.drawTextEx(
                        font,
                        try frame_arena_alloc.dupeZ(u8, render_text),
                        .{ .x = bounding_box.x, .y = bounding_box.y },
                        @floatFromInt(config.font_size),
                        @floatFromInt(config.letter_spacing),
                        rl_color_from_arr(config.color),
                    );
                },
                .rectangle => {
                    const config = render_command.config.rectangle_config;
                    if (config.corner_radius.top_left > 0) {
                        const radius = (config.corner_radius.top_left * 2) / @max(bounding_box.width, bounding_box.height);
                        rl.drawRectangleRounded(
                            rec,
                            radius,
                            8,
                            rl_color_from_arr(config.color),
                        );
                    } else {
                        rl.drawRectangleRec(
                            rec,
                            rl_color_from_arr(config.color),
                        );
                    }
                },
                .border => {
                    const config = render_command.config.border_config;
                    // Left border
                    if (config.left.width > 0) {
                        rl.drawRectangle(
                            @intFromFloat(@round(bounding_box.x)),
                            @intFromFloat(@round(bounding_box.y + config.corner_radius.top_left)),
                            @intCast(config.left.width),
                            @intFromFloat(@round(bounding_box.height - config.corner_radius.top_left - config.corner_radius.bottom_left)),
                            rl_color_from_arr(config.left.color),
                        );
                    }
                    // Right border
                    if (config.right.width > 0) {
                        rl.drawRectangle(
                            @intFromFloat(@round(bounding_box.x + bounding_box.width - @as(f32, @floatFromInt(config.right.width)))),
                            @intFromFloat(@round(bounding_box.y + config.corner_radius.top_right)),
                            @intCast(config.right.width),
                            @intFromFloat(@round(bounding_box.height - config.corner_radius.top_right - config.corner_radius.bottom_right)),
                            rl_color_from_arr(config.right.color),
                        );
                    }
                    // Top border
                    if (config.top.width > 0) {
                        rl.drawRectangle(
                            @intFromFloat(@round(bounding_box.x + config.corner_radius.top_left)),
                            @intFromFloat(@round(bounding_box.y)),
                            @intFromFloat(@round(bounding_box.width - config.corner_radius.top_left - config.corner_radius.top_right)),
                            @intCast(config.top.width),
                            rl_color_from_arr(config.top.color),
                        );
                    }
                    // Bottom border
                    if (config.bottom.width > 0) {
                        rl.drawRectangle(
                            @intFromFloat(@round(bounding_box.x + config.corner_radius.bottom_left)),
                            @intFromFloat(@round(bounding_box.y + bounding_box.height - @as(f32, @floatFromInt(config.bottom.width)))),
                            @intFromFloat(@round(bounding_box.width - config.corner_radius.bottom_left - config.corner_radius.bottom_right)),
                            @intCast(config.bottom.width),
                            rl_color_from_arr(config.bottom.color),
                        );
                    }
                    // Corner rings
                    if (config.corner_radius.top_left > 0) {
                        rl.drawRing(
                            .{
                                .x = @round(bounding_box.x + config.corner_radius.top_left),
                                .y = @round(bounding_box.y + config.corner_radius.top_left),
                            },
                            @round(config.corner_radius.top_left - @as(f32, @floatFromInt(config.top.width))),
                            config.corner_radius.top_left,
                            180,
                            270,
                            10,
                            rl_color_from_arr(config.top.color),
                        );
                    }
                    if (config.corner_radius.top_right > 0) {
                        rl.drawRing(
                            .{
                                .x = @round(bounding_box.x + bounding_box.width - config.corner_radius.top_right),
                                .y = @round(bounding_box.y + config.corner_radius.top_right),
                            },
                            @round(config.corner_radius.top_right - @as(f32, @floatFromInt(config.top.width))),
                            config.corner_radius.top_right,
                            270,
                            360,
                            10,
                            rl_color_from_arr(config.top.color),
                        );
                    }
                    if (config.corner_radius.bottom_left > 0) {
                        rl.drawRing(
                            .{
                                .x = @round(bounding_box.x + config.corner_radius.bottom_left),
                                .y = @round(bounding_box.y + bounding_box.height - config.corner_radius.bottom_left),
                            },
                            @round(config.corner_radius.bottom_left - @as(f32, @floatFromInt(config.top.width))),
                            config.corner_radius.bottom_left,
                            90,
                            180,
                            10,
                            rl_color_from_arr(config.bottom.color),
                        );
                    }
                    if (config.corner_radius.bottom_right > 0) {
                        rl.drawRing(
                            .{
                                .x = @round(bounding_box.x + bounding_box.width - config.corner_radius.bottom_right),
                                .y = @round(bounding_box.y + bounding_box.height - config.corner_radius.bottom_right),
                            },
                            @round(config.corner_radius.bottom_right - @as(f32, @floatFromInt(config.bottom.width))),
                            config.corner_radius.bottom_right,
                            0.1,
                            90,
                            10,
                            rl_color_from_arr(config.bottom.color),
                        );
                    }
                },
                .scissor_start => {
                    rl.beginScissorMode(
                        @intFromFloat(bounding_box.x),
                        @intFromFloat(bounding_box.y),
                        @intFromFloat(bounding_box.width),
                        @intFromFloat(bounding_box.height),
                    );
                },
                .scissor_end => {
                    rl.endScissorMode();
                },
                .image => unreachable,
                .custom => {
                    const config = render_command.config.custom_config;
                    const data: *ClayCustom = @ptrCast(@alignCast(config.custom_data));
                    switch (data.*) {
                        .none => {},
                        .squarified_treemap => |treemap_data| {
                            const dir_entries = treemap_data.dir_entries;
                            const rect: rl.Rectangle = .{
                                .x = bounding_box.x,
                                .y = bounding_box.y,
                                .width = bounding_box.width,
                                .height = bounding_box.height,
                            };
                            squarify(frame_arena_alloc, dir_entries, rect);
                        },
                    }
                },
            }
        }

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

            rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, debug_text_size);

            const dbg_text = std.fmt.allocPrintZ(frame_arena_alloc, "FPS={: >4} | FT={: >4}ms | IDX={: >5}/s | FILES={}", .{
                frame_rate,
                round_to_decimal_places(frame_time / std.time.ms_per_s, 5),
                round_to_decimal_places(files_per_second, 5),
                files_total,
            }) catch {
                break :dbg;
            };
            rl.drawText(dbg_text, 0, rl.getRenderHeight() - debug_text_size - 5, debug_text_size, rl.Color.black);
        }
    }
}
const DirEntry = struct {
    name: [:0]const u8,
    size_bytes: u64,
    fs_store_entry_ptr: *lib.FS_Store.Entry,

    fn gt_than(_: void, lhs: DirEntry, rhs: DirEntry) bool {
        if (lhs.size_bytes == rhs.size_bytes) {
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
        return lhs.size_bytes > rhs.size_bytes;
    }
};

// https://cgl.ethz.ch/teaching/scivis_common/Literature/squarifiedTreeMaps.pdf
// https://github.com/nicopolyptic/treemap/blob/master/src/main/ts/squarifier.ts
fn squarify(alloc: Allocator, dir_entries: []const DirEntry, rect: rl.Rectangle) void {
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
                rl.drawRectangleLinesEx(rec, 3, rl.Color.light_gray);
                ry = ry + d;
            } else {
                const rec = .{ .x = rx, .y = ry, .width = d, .height = z };
                rl.drawRectangleRec(rec, color);
                rl.drawRectangleLinesEx(rec, 3, rl.Color.light_gray);
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

pub const ColorScheme = union(enum) {
    rainbow: void,
    sample: colormaps.options,
};

pub fn generate_palette(
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

fn clay_measure_text(text: []const u8, ctx: *clay.TextElementConfig) clay.Dimensions {
    var textSize: clay.Dimensions = .{ .w = 0, .h = 0 };

    const size = text.len;

    var tempByteCounter: u32 = 0; // Used to count longer text line num chars
    var byteCounter: u32 = 0;

    var textWidth: f32 = 0.0;
    var tempTextWidth: f32 = 0.0; // Used to count longer text line width

    const font = fonts[ctx.font_id];

    const font_size: f32 = @floatFromInt(ctx.font_size);
    var textHeight: f32 = font_size;
    const scaleFactor: f32 = font_size / @as(f32, @floatFromInt(font.baseSize));
    const line_spacing: f32 = @as(f32, @floatFromInt(ctx.line_height)) - textHeight;

    var letter: i32 = 0;
    var index: u32 = 0;

    var i: i32 = 0;
    while (i < size) {
        byteCounter += 1;

        var codepointByteCount: i32 = 0;
        letter = rl.getCodepointNext(@ptrCast(&text[@abs(i)]), &codepointByteCount);
        index = @intCast(rl.getGlyphIndex(font, letter));

        i += codepointByteCount;

        if (letter != '\n') {
            if (font.glyphs[index].advanceX > 0) {
                textWidth += @floatFromInt(font.glyphs[index].advanceX);
            } else {
                textWidth += font.recs[index].width + @as(f32, @floatFromInt(font.glyphs[index].offsetX));
            }
        } else {
            tempTextWidth = @max(tempTextWidth, textWidth);
            byteCounter = 0;
            textWidth = 0;

            // NOTE(raylib): Line spacing is a global variable, use SetTextLineSpacing() to setup
            textHeight += font_size + line_spacing;
        }

        if (tempByteCounter < byteCounter) tempByteCounter = byteCounter;
    }

    if (tempTextWidth < textWidth) tempTextWidth = textWidth;

    textSize.w = tempTextWidth * scaleFactor + @as(f32, @floatFromInt((tempByteCounter - 1) * ctx.letter_spacing));
    textSize.h = textHeight;

    return textSize;
}

fn rl_color_to_arr(color: rl.Color) [4]f32 {
    return .{ @floatFromInt(color.r), @floatFromInt(color.g), @floatFromInt(color.b), @floatFromInt(color.a) };
}

fn rl_color_from_arr(arr: [4]f32) rl.Color {
    return .{
        .r = @intFromFloat(arr[0]),
        .g = @intFromFloat(arr[1]),
        .b = @intFromFloat(arr[2]),
        .a = @intFromFloat(arr[3]),
    };
}

fn clay_border_all(color: clay.Color, width: u16, radius: f32) clay.BorderElementConfig {
    const data = clay.BorderData{ .color = color, .width = width };
    return clay.BorderElementConfig{
        .left = data,
        .right = data,
        .top = data,
        .bottom = data,
        .between_children = .{},
        .corner_radius = .{
            .top_left = radius,
            .bottom_left = radius,
            .top_right = radius,
            .bottom_right = radius,
        },
    };
}

const ClayCustom = union(enum) {
    none: void,
    squarified_treemap: struct {
        dir_entries: []const DirEntry,
    },

    const NONE: ClayCustom = .{ .none = {} };

    pub fn none() clay.Config {
        return clay.Config.custom(.{ .custom_data = @ptrCast(@constCast(&NONE)) });
    }
};
