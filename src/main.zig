const std = @import("std");
const lib = @import("root.zig");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const c = @cImport(@cInclude("sqlite3.h"));

const rl = @import("raylib");
const rgui = @import("raygui");

const WORKER_THREAD_COUNT_MAX = 4;

pub fn main() anyerror!void {
    // Initialization
    //--------------------------------------------------------------------------------------
    const screenWidth = 600;
    const screenHeight = 800;

    rl.setConfigFlags(.{
        .window_undecorated = true,
        .window_unfocused = true,
        .window_resizable = true,
        .window_topmost = false,
    });
    rl.initWindow(screenWidth, screenHeight, "CHONK");
    defer rl.closeWindow(); // Close window and OpenGL context

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    std.debug.print("INFO path_size_bytes: {d}\n", .{std.fs.max_path_bytes});

    const alloc_state = std.heap.page_allocator;

    var frame_arena = std.heap.ArenaAllocator.init(alloc_state);
    const frame_arena_alloc = frame_arena.allocator();

    var connection_pool = try lib.DB.init_pool(alloc_state, 4);
    const conn = connection_pool.acquire();
    try lib.DB.ensure_init(conn);
    connection_pool.release(conn);
    if (c.sqlite3_config(c.SQLITE_CONFIG_LOG, error_log_callback, c.SQLITE_NULL) != c.SQLITE_OK) {
        std.debug.print("WARN: Failed to setup db logging\n", .{});
    }

    const Page = union(enum) {
        select: struct {
            paths: ?[]lib.TopLevelPath = null,
        },
        viewer: struct {
            path: [:0]const u8,
            worker_thread_pool: Thread.Pool = undefined,
            worker_thread_pool_running: Thread.ResetEvent = .{},
            worker_thread_pool_queue: lib.DirQueue = undefined,
            fs_store: lib.FS_Store = undefined,
            trickle_queue: lib.AtomicQueue(lib.FileSizeEntry) = undefined,
            scroll_state: rl.Vector2 = undefined,
            scroll_view: rl.Rectangle = undefined,
            query_thread: ?Thread = null,
            dir_entries: DirEntriesThreadState = .{},
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
                if (select_data.paths == null) {
                    select_data.paths = lib.get_top_level_paths(alloc_state, frame_arena_alloc) catch |err| {
                        std.debug.print("ERROR: Failed to retrieve file paths: {any}\n", .{err});
                        break :frame;
                    };
                }
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
                        page_current = .{
                            .viewer = .{
                                .path = file_path,
                            },
                        };
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

                    const dbg_text = std.fmt.allocPrintZ(frame_arena_alloc, "FPS={: >4} | FT={: >4}ms | IDX={: >5}/s", .{
                        frame_rate,
                        round_to_decimal_places(frame_time / std.time.ms_per_s, 5),
                        round_to_decimal_places(files_per_second, 5),
                    }) catch {
                        break :dbg;
                    };
                    rl.drawText(dbg_text, 0, rl.getRenderHeight() - debug_text_size - 5, debug_text_size, rl.Color.black);
                };
                if (viewer_data.dir_entries.thread == null) dir_entries: {
                    viewer_data.dir_entries.alive_mutex.lock();
                    const thread = Thread.spawn(.{}, dir_entries_thread_impl, .{
                        &viewer_data.dir_entries, viewer_data.path, connection_pool,
                    }) catch |err| {
                        std.debug.print("ERROR: failed to spawn query thread: {any}\n", .{err});
                        viewer_data.dir_entries.alive_mutex.unlock();
                        break :dir_entries;
                    };
                    thread.detach();
                    viewer_data.dir_entries.thread = thread;
                }
                if (!viewer_data.worker_thread_pool_running.isSet()) worker: {
                    viewer_data.worker_thread_pool_running.set();
                    Thread.Pool.init(&viewer_data.worker_thread_pool, .{
                        .allocator = alloc_state,
                        .n_jobs = WORKER_THREAD_COUNT_MAX,
                    }) catch |err| {
                        std.debug.print("ERROR: failed to create worker thread pool: {any}\n", .{err});
                        viewer_data.worker_thread_pool_running.reset();
                        viewer_data.worker_thread_pool.deinit();
                        break :worker;
                    };
                    try viewer_data.worker_thread_pool_queue.init(alloc_state, 1024);
                    {
                        const tl_conn = connection_pool.acquire();
                        defer connection_pool.release(conn);
                        var dir = try std.fs.openDirAbsolute(viewer_data.path, .{ .iterate = true });
                        defer dir.close();
                        var dir_iter = dir.iterate();
                        while (dir_iter.next() catch null) |entry| {
                            const abs_path = std.fs.path.join(frame_arena_alloc, &.{ viewer_data.path, entry.name }) catch continue;
                            switch (entry.kind) {
                                .file => {
                                    try lib.DB.entries_save_one(tl_conn, .{
                                        .kind = .file,
                                        .size_bytes = stat: {
                                            const file = std.fs.openFileAbsolute(abs_path, .{ .mode = .read_only }) catch break :stat 0;
                                            const stat = file.stat() catch break :stat 0;
                                            break :stat stat.size;
                                        },
                                        .abs_path = abs_path,
                                    });
                                },
                                .directory => {
                                    try lib.DB.entries_save_one(tl_conn, .{
                                        .kind = .dir,
                                        .size_bytes = 0,
                                        .abs_path = abs_path,
                                    });
                                },
                                .sym_link => {
                                    try lib.DB.entries_save_one(tl_conn, .{
                                        .kind = .link_soft,
                                        .size_bytes = 0,
                                        .abs_path = abs_path,
                                    });
                                },
                                else => continue,
                            }
                            try viewer_data.worker_thread_pool_queue.enqueue(abs_path);
                        }
                    }
                    try viewer_data.fs_store.init();

                    viewer_data.worker_thread_pool.spawn(lib.index_paths_starting_with, .{ viewer_data.path, alloc_state, &viewer_data.fs_store, &viewer_data.worker_thread_pool_running, &viewer_data.dbg.files_indexed }) catch |err| {
                        std.debug.print("ERROR: failed to spawn worker thread: {any}\n", .{err});
                        // viewer_data.worker_thread_pool_running.reset();
                        // viewer_data.worker_thread_pool.deinit();
                        // try viewer_data.worker_thread_pool_queue.enqueue(dir);
                    };
                }

                if (false) {
                    const new_dirs = try viewer_data.worker_thread_pool_queue.empty(alloc_state);
                    defer alloc_state.free(new_dirs);
                    if (new_dirs.len > 0) {
                        std.debug.print("Found new dirs:\n", .{});
                    }
                    for (new_dirs) |dir| {
                        std.debug.print("\t'{s}'\n", .{dir});
                        viewer_data.worker_thread_pool.spawn(lib.index_paths_starting_with, .{ dir, alloc_state, &viewer_data.fs_store, &viewer_data.worker_thread_pool_running, &viewer_data.dbg.files_indexed }) catch |err| {
                            std.debug.print("ERROR: failed to spawn worker thread: {any}\n", .{err});
                            viewer_data.worker_thread_pool_running.reset();
                            viewer_data.worker_thread_pool.deinit();
                            try viewer_data.worker_thread_pool_queue.enqueue(dir);
                        };
                    }
                }
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
                        viewer_data.worker_thread_pool_running.reset();
                        viewer_data.worker_thread_pool.deinit();
                        viewer_data.dir_entries.alive_mutex.unlock();
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

                viewer_data.dir_entries.data_mutex.lock();
                defer viewer_data.dir_entries.data_mutex.unlock();
                const dir_entries = viewer_data.dir_entries.data;

                // std.debug.print("FOUND {d} entries\n", .{dir_entries.len});

                const path_font_size = 32;
                const path_height = 60;

                const window_width_f32: f32 = @floatFromInt(window_width);
                const window_height_f32: f32 = @floatFromInt(rl.getRenderHeight());
                const scroll_width = window_width_f32 * 0.8;
                const scroll_height = window_height_f32 - @as(f32, @floatFromInt(label_height)) - 100;

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
                const path_x = scroll_bounds.x;

                rgui.guiSetStyle(.default, rgui.GuiDefaultProperty.text_size, path_font_size);

                for (dir_entries, 0..) |file, i| {
                    const path_y = scroll_bounds.y + @as(f32, @floatFromInt((i * path_height))) + viewer_data.scroll_state.y; // 30 pixels spacing between lines
                    rl.drawText(
                        try frame_arena_alloc.dupeZ(u8, std.fs.path.basename(file.abs_path)),
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
                        @intFromFloat(scroll_bounds.x + scroll_bounds.width - size_text_size.x - 50),
                        @intFromFloat(path_y),
                        path_font_size,
                        rl.Color.black,
                    );
                }
                rl.endScissorMode();
            },
        }
    }
}

const DirEntriesThreadState = struct {
    data: []lib.DB.Entry = &.{},
    thread: ?Thread = null,
    data_mutex: Thread.Mutex = Thread.Mutex{},
    alive_mutex: Thread.Mutex = Thread.Mutex{},
    arenas: ArenaPair = .{
        .a = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .b = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    },

    const ArenaPair = struct {
        a: std.heap.ArenaAllocator,
        b: std.heap.ArenaAllocator,
    };
};

fn dir_entries_thread_impl(state: *DirEntriesThreadState, path: []const u8, connection_pool: *lib.sqlite.Pool) void {
    const conn = connection_pool.acquire();
    defer connection_pool.release(conn);

    defer state.arenas.a.deinit();
    defer state.arenas.b.deinit();

    while (!state.alive_mutex.tryLock()) {
        // const time_now = std.time.nanoTimestamp();
        const new_data = lib.DB.entries_get_direct_children_of(conn, state.arenas.b.allocator(), path) catch |err| {
            std.debug.print("ERROR: failed to retrieve dir entries: {any}\n", .{err});
            continue;
        };
        // const time_end = std.time.nanoTimestamp();
        // std.debug.print("INFO: query took {d}ms\n", .{
        //     @divTrunc(time_end - time_now, std.time.ns_per_ms),
        // });
        // atomic_swap:
        {
            state.data_mutex.lock();
            defer state.data_mutex.unlock();
            state.data = new_data;
        }
        std.mem.swap(std.heap.ArenaAllocator, &state.arenas.a, &state.arenas.b);
        _ = state.arenas.b.reset(.retain_capacity);
        // std.time.sleep(500 * std.time.ns_per_ms);
        // Thread.yield() catch continue;
    }
    state.alive_mutex.unlock();
}

fn error_log_callback(_: *allowzero anyopaque, error_code: c_int, msg: [*:0]const u8) callconv(.C) void {
    std.debug.print("ERROR(SQLITE_LOG): {d} {s}\n", .{ error_code, msg });
}

fn pad(rect: rl.Rectangle, x: f32, y: f32) rl.Rectangle {
    return rl.Rectangle{
        .x = rect.x + x,
        .y = rect.y + y,
        .height = rect.height - y,
        .width = rect.width - x,
    };
}

fn fmt_file_size(alloc: Allocator, bytes: u64) [:0]const u8 {
    return std.fmt.allocPrintZ(alloc, "{}", .{std.fmt.fmtIntSizeDec(bytes)}) catch "";
}

fn round_to_decimal_places(value: f64, decimal_places: usize) f64 {
    const factor = std.math.pow(f64, 10.0, @floatFromInt(decimal_places));
    return std.math.round(value * factor) / factor;
}
