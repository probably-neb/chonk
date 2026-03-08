const clay = @import("clay");
const rl = @import("raylib");
const std = @import("std");
const Allocator = std.mem.Allocator;

const text = @import("text");
const ui = @import("ui");
const ClayCustom = ui.ClayCustom;

const frame_arena = @import("bin").frame_arena_alloc;

pub fn draw() !void {
    const ui_draw_commands = clay.endLayout();

    for (ui_draw_commands) |render_command| {
        const bounding_box = render_command.bounding_box;
        const rec: rl.Rectangle = .{
            .x = bounding_box.x,
            .y = bounding_box.y,
            .width = bounding_box.width,
            .height = bounding_box.height,
        };
        switch (render_command.command_type) {
            .none => {},
            .text => {
                const config = render_command.render_data.text;
                const render_text = config.string_contents.chars[0..@abs(config.string_contents.length)];

                text.font_system.drawText(
                    render_text,
                    .{ .x = bounding_box.x, .y = bounding_box.y },
                    @floatFromInt(config.font_size),
                    @floatFromInt(config.letter_spacing),
                    rl_color_from_arr(config.text_color),
                );
            },
            .rectangle => {
                const config = render_command.render_data.rectangle;
                if (config.corner_radius.top_left > 0) {
                    const radius = (config.corner_radius.top_left * 2) / @max(bounding_box.width, bounding_box.height);
                    rl.drawRectangleRounded(
                        rec,
                        radius,
                        8,
                        rl_color_from_arr(config.background_color),
                    );
                } else {
                    rl.drawRectangleRec(
                        rec,
                        rl_color_from_arr(config.background_color),
                    );
                }
            },
            .border => {
                const config = render_command.render_data.border;
                // Left border
                if (config.width.left > 0) {
                    rl.drawRectangle(
                        @intFromFloat(@round(bounding_box.x)),
                        @intFromFloat(@round(bounding_box.y + config.corner_radius.top_left)),
                        @intCast(config.width.left),
                        @intFromFloat(@round(bounding_box.height - config.corner_radius.top_left - config.corner_radius.bottom_left)),
                        rl_color_from_arr(config.color),
                    );
                }
                // Right border
                if (config.width.right > 0) {
                    rl.drawRectangle(
                        @intFromFloat(@round(bounding_box.x + bounding_box.width - @as(f32, @floatFromInt(config.width.right)))),
                        @intFromFloat(@round(bounding_box.y + config.corner_radius.top_right)),
                        @intCast(config.width.right),
                        @intFromFloat(@round(bounding_box.height - config.corner_radius.top_right - config.corner_radius.bottom_right)),
                        rl_color_from_arr(config.color),
                    );
                }
                // Top border
                if (config.width.top > 0) {
                    rl.drawRectangle(
                        @intFromFloat(@round(bounding_box.x + config.corner_radius.top_left)),
                        @intFromFloat(@round(bounding_box.y)),
                        @intFromFloat(@round(bounding_box.width - config.corner_radius.top_left - config.corner_radius.top_right)),
                        @intCast(config.width.top),
                        rl_color_from_arr(config.color),
                    );
                }
                // Bottom border
                if (config.width.bottom > 0) {
                    rl.drawRectangle(
                        @intFromFloat(@round(bounding_box.x + config.corner_radius.bottom_left)),
                        @intFromFloat(@round(bounding_box.y + bounding_box.height - @as(f32, @floatFromInt(config.width.bottom)))),
                        @intFromFloat(@round(bounding_box.width - config.corner_radius.bottom_left - config.corner_radius.bottom_right)),
                        @intCast(config.width.bottom),
                        rl_color_from_arr(config.color),
                    );
                }
                // Corner rings
                if (config.corner_radius.top_left > 0) {
                    rl.drawRing(
                        .{
                            .x = @round(bounding_box.x + config.corner_radius.top_left),
                            .y = @round(bounding_box.y + config.corner_radius.top_left),
                        },
                        @round(config.corner_radius.top_left - @as(f32, @floatFromInt(config.width.top))),
                        config.corner_radius.top_left,
                        180,
                        270,
                        10,
                        rl_color_from_arr(config.color),
                    );
                }
                if (config.corner_radius.top_right > 0) {
                    rl.drawRing(
                        .{
                            .x = @round(bounding_box.x + bounding_box.width - config.corner_radius.top_right),
                            .y = @round(bounding_box.y + config.corner_radius.top_right),
                        },
                        @round(config.corner_radius.top_right - @as(f32, @floatFromInt(config.width.top))),
                        config.corner_radius.top_right,
                        270,
                        360,
                        10,
                        rl_color_from_arr(config.color),
                    );
                }
                if (config.corner_radius.bottom_left > 0) {
                    rl.drawRing(
                        .{
                            .x = @round(bounding_box.x + config.corner_radius.bottom_left),
                            .y = @round(bounding_box.y + bounding_box.height - config.corner_radius.bottom_left),
                        },
                        @round(config.corner_radius.bottom_left - @as(f32, @floatFromInt(config.width.top))),
                        config.corner_radius.bottom_left,
                        90,
                        180,
                        10,
                        rl_color_from_arr(config.color),
                    );
                }
                if (config.corner_radius.bottom_right > 0) {
                    rl.drawRing(
                        .{
                            .x = @round(bounding_box.x + bounding_box.width - config.corner_radius.bottom_right),
                            .y = @round(bounding_box.y + bounding_box.height - config.corner_radius.bottom_right),
                        },
                        @round(config.corner_radius.bottom_right - @as(f32, @floatFromInt(config.width.bottom))),
                        config.corner_radius.bottom_right,
                        0.1,
                        90,
                        10,
                        rl_color_from_arr(config.color),
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
                const config = render_command.render_data.custom;
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
                        @import("squarified-tree-map.zig").squarify(frame_arena, dir_entries, rect);
                    },
                }
            },
        }
    }
}

pub fn rl_color_to_arr(color: rl.Color) [4]f32 {
    return .{ @floatFromInt(color.r), @floatFromInt(color.g), @floatFromInt(color.b), @floatFromInt(color.a) };
}

pub fn rl_color_from_arr(arr: [4]f32) rl.Color {
    return .{
        .r = @intFromFloat(arr[0]),
        .g = @intFromFloat(arr[1]),
        .b = @intFromFloat(arr[2]),
        .a = @intFromFloat(arr[3]),
    };
}
