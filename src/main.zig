const std = @import("std");
const lib = @import("root.zig");

const rl = @import("raylib");
const rgui = @import("raygui");

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

    const alloc_state = std.heap.page_allocator;

    const Page = union(enum) {
        select: struct {
            paths: ?[][*:0]const u8,
        },
        viewer: void,
    };

    var page_current: Page = .{
        .select = .{ .paths = null },
    };

    const font = try rl.getFontDefault();

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        // Update
        //----------------------------------------------------------------------------------
        // TODO: Update your variables here
        //----------------------------------------------------------------------------------

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.white);

        switch (page_current) {
            .select => |*select_data| blk: {
                if (select_data.paths == null) {
                    select_data.paths = lib.get_top_level_paths(alloc_state) catch |err| {
                        std.debug.print("ERROR: Failed to retrieve file paths: {any}\n", .{err});
                        break :blk;
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
                    const path_y = @as(f32, @floatFromInt(label_height + @as(i32, @intCast((i * path_height))))); // 30 pixels spacing between lines
                    if (rgui.guiButton(.{
                        .x = path_x,
                        .y = path_y,
                        .width = path_width,
                        .height = path_height,
                    }, file) != 0) {
                        std.debug.print("clicked {s}\n", .{file});
                    }
                }
            },
            .viewer => {},
        }

        // const res = rgui.guiListView(rl.Rectangle{
        //     .x = 0.0,
        //     .y = 0.0,
        //     .width = @floatFromInt(rl.getRenderWidth()),
        //     .height = @floatFromInt(rl.getRenderHeight()),
        // }, "My List", &file_list_scroll_index, &file_list_active);

        // Draw each file name in the list
        //----------------------------------------------------------------------------------
    }
}
