pub const FontSystem = @import("font_system.zig").FontSystem;
pub const glyph_cache = @import("glyph_cache.zig");
const rl = @import("raylib");

pub var font_system: FontSystem = undefined;

pub fn init(alloc: @import("std").mem.Allocator) !void {
    font_system = try FontSystem.init(alloc, 32, 2048, 2048);
}

pub fn clay_measure_text(text_value: []const u8, ctx: *@import("clay").TextElementConfig, user_data: void) @import("clay").Dimensions {
    _ = user_data;
    const measured = font_system.measureText(
        text_value,
        @floatFromInt(ctx.font_size),
        @floatFromInt(ctx.letter_spacing),
    );
    return .{
        .w = measured.x,
        .h = measured.y,
    };
}

pub fn measure_text(text_value: []const u8, font_size: f32, letter_spacing: f32) rl.Vector2 {
    return font_system.measureText(
        text_value,
        font_size,
        letter_spacing,
    );
}
