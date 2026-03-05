const std = @import("std");
const rl = @import("raylib");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");

const glyph_cache = @import("glyph_cache.zig");

const embedded_font_bytes = @embedFile("../assets/fonts/FiraSans-Regular.ttf");

pub const FontSystem = struct {
    allocator: std.mem.Allocator,

    ft_lib: freetype.Library,
    ft_face: freetype.Face,

    hb_font: harfbuzz.Font,

    cache: glyph_cache.GlyphCache,

    base_font_px: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        font_px: u32,
        atlas_w: i32,
        atlas_h: i32,
    ) !FontSystem {
        const ft_lib = try freetype.Library.init();
        errdefer ft_lib.deinit();

        const ft_face = try ft_lib.createFaceMemory(embedded_font_bytes, 0);
        errdefer ft_face.deinit();

        try ft_face.setPixelSizes(0, font_px);

        const hb_font = harfbuzz.Font.fromFreetypeFace(ft_face);
        errdefer hb_font.deinit();

        // Keep FreeType pixel size as the source of truth.
        // Sync HarfBuzz once at creation and after each FT size change.
        hb_font.freetypeFaceChanged();

        const cache = try glyph_cache.GlyphCache.init(allocator, atlas_w, atlas_h);
        errdefer {
            var c = cache;
            c.deinit();
        }

        return .{
            .allocator = allocator,
            .ft_lib = ft_lib,
            .ft_face = ft_face,
            .hb_font = hb_font,
            .cache = cache,
            .base_font_px = font_px,
        };
    }

    pub fn deinit(self: *FontSystem) void {
        self.cache.deinit();
        self.hb_font.deinit();
        self.ft_face.deinit();
        self.ft_lib.deinit();
        self.* = undefined;
    }

    pub fn measureText(
        self: *FontSystem,
        text: []const u8,
        font_size: f32,
        letter_spacing: f32,
    ) rl.Vector2 {
        if (text.len == 0) return .{ .x = 0, .y = 0 };

        const px_size = pxSizeFromFloat(font_size) catch self.base_font_px;

        var shape_buf = harfbuzz.Buffer.init() orelse return .{ .x = 0, .y = 0 };
        defer shape_buf.deinit();

        shape_buf.addUTF8(text, 0, null);
        shape_buf.guessSegmentProps();

        self.setFontSize(px_size) catch return .{ .x = 0, .y = 0 };
        self.hb_font.shape(shape_buf, null);

        const positions_opt = shape_buf.getGlyphPositions();
        const positions = positions_opt orelse return .{ .x = 0, .y = 0 };
        if (positions.len == 0) return .{ .x = 0, .y = 0 };

        var pen_x: f32 = 0.0;

        for (positions, 0..) |pos, i| {
            pen_x += f26_6ToF32(pos.x_advance);
            if (i + 1 < positions.len) pen_x += letter_spacing;
        }

        const advance_width = @max(0.0, pen_x);

        const size_metrics = self.ft_face.size().metrics();
        const h = f26_6ToF32(@intCast(size_metrics.ascender - size_metrics.descender));

        return .{
            .x = advance_width,
            .y = @max(@as(f32, 0.0), h),
        };
    }

    pub fn drawText(
        self: *FontSystem,
        text: []const u8,
        position: rl.Vector2,
        font_size: f32,
        letter_spacing: f32,
        color: rl.Color,
    ) void {
        if (text.len == 0) return;

        const px_size = pxSizeFromFloat(font_size) catch self.base_font_px;

        var shape_buf = harfbuzz.Buffer.init() orelse return;
        defer shape_buf.deinit();

        shape_buf.addUTF8(text, 0, null);
        shape_buf.guessSegmentProps();

        self.setFontSize(px_size) catch return;
        self.hb_font.shape(shape_buf, null);

        const infos = shape_buf.getGlyphInfos();
        const positions_opt = shape_buf.getGlyphPositions();
        const positions = positions_opt orelse return;
        if (positions.len == 0) return;

        // Incoming position is top-left of text box (Clay contract).
        // Convert to baseline by adding ascender from current face metrics.
        const size_metrics = self.ft_face.size().metrics();
        const ascender_px = f26_6ToF32(@intCast(size_metrics.ascender));
        const baseline_y: f32 = position.y + ascender_px;

        var pen_x: f32 = position.x;

        rl.beginBlendMode(.alpha);
        defer rl.endBlendMode();

        for (infos, positions, 0..) |info, pos, i| {
            const entry = self.getOrCreateGlyph(info.codepoint, px_size) catch {
                pen_x += f26_6ToF32(pos.x_advance);
                if (i + 1 < positions.len) pen_x += letter_spacing;
                continue;
            };

            if (entry.w > 0 and entry.h > 0) {
                const src = rl.Rectangle{
                    .x = @floatFromInt(entry.x),
                    .y = @floatFromInt(entry.y),
                    .width = @floatFromInt(entry.w),
                    .height = @floatFromInt(entry.h),
                };

                const dest_x = pen_x + f26_6ToF32(pos.x_offset) + @as(f32, @floatFromInt(entry.bearing_x));
                const dest_y = baseline_y - @as(f32, @floatFromInt(entry.bearing_y)) - f26_6ToF32(pos.y_offset);

                const dst = rl.Rectangle{
                    .x = dest_x,
                    .y = dest_y,
                    .width = @floatFromInt(entry.w),
                    .height = @floatFromInt(entry.h),
                };

                rl.drawTexturePro(
                    self.cache.atlas,
                    src,
                    dst,
                    .{ .x = 0, .y = 0 },
                    0,
                    color,
                );
            }

            pen_x += f26_6ToF32(pos.x_advance);
            if (i + 1 < positions.len) pen_x += letter_spacing;
        }
    }

    fn setFontSize(self: *FontSystem, px_size: u32) !void {
        try self.ft_face.setPixelSizes(0, px_size);
        self.hb_font.freetypeFaceChanged();
    }

    fn getOrCreateGlyph(
        self: *FontSystem,
        glyph_id: u32,
        px_size: u32,
    ) !*const glyph_cache.GlyphEntry {
        const key = glyph_cache.GlyphKey{
            .glyph_id = glyph_id,
            .pixel_size = px_size,
        };

        if (self.cache.lookup(key)) |entry| return entry;

        return self.rasterAndCacheGlyph(key);
    }

    fn rasterAndCacheGlyph(
        self: *FontSystem,
        key: glyph_cache.GlyphKey,
    ) !*const glyph_cache.GlyphEntry {
        try self.ft_face.loadGlyph(key.glyph_id, .{});
        const slot = self.ft_face.glyph();
        try slot.render(.normal);
        const bmp = slot.bitmap();

        const w: i32 = @intCast(bmp.width());
        const h: i32 = @intCast(bmp.rows());

        const bearing_x = slot.bitmapLeft();
        const bearing_y = slot.bitmapTop();
        const advance_x_26_6: i32 = @intCast(slot.advance().x);

        var alpha_storage: []u8 = &.{};

        if (w > 0 and h > 0) {
            const rows: usize = @intCast(h);
            const cols: usize = @intCast(w);
            const pitch_i32 = bmp.pitch();
            const pitch_abs: usize = @intCast(@abs(pitch_i32));

            alpha_storage = try self.allocator.alloc(u8, rows * cols);
            @memset(alpha_storage, 0);

            const src: []const u8 = bmp.buffer() orelse return error.MissingGlyphBitmap;
            const needed = rows * pitch_abs;
            if (src.len < needed) return error.InvalidGlyphBitmapBuffer;

            switch (bmp.pixelMode()) {
                .gray => {
                    if (pitch_abs < cols) return error.InvalidGlyphBitmapPitch;

                    for (0..rows) |row| {
                        const src_row_index = if (pitch_i32 >= 0) row else (rows - 1 - row);
                        const src_off = src_row_index * pitch_abs;
                        const src_row = src[src_off .. src_off + cols];
                        const dst_off = row * cols;
                        const dst_row = alpha_storage[dst_off .. dst_off + cols];
                        @memcpy(dst_row, src_row);
                    }
                },
                .gray2 => {
                    const row_bytes = (cols + 3) / 4;
                    if (pitch_abs < row_bytes) return error.InvalidGlyphBitmapPitch;

                    for (0..rows) |row| {
                        const src_row_index = if (pitch_i32 >= 0) row else (rows - 1 - row);
                        const src_off = src_row_index * pitch_abs;
                        const src_row = src[src_off .. src_off + row_bytes];
                        const dst_off = row * cols;
                        const dst_row = alpha_storage[dst_off .. dst_off + cols];

                        for (0..cols) |col| {
                            const b = src_row[col / 4];
                            const shift: u3 = @intCast(6 - ((col & 3) * 2));
                            const v2: u8 = (b >> shift) & 0x03;
                            dst_row[col] = @as(u8, v2 * 85);
                        }
                    }
                },
                .gray4 => {
                    const row_bytes = (cols + 1) / 2;
                    if (pitch_abs < row_bytes) return error.InvalidGlyphBitmapPitch;

                    for (0..rows) |row| {
                        const src_row_index = if (pitch_i32 >= 0) row else (rows - 1 - row);
                        const src_off = src_row_index * pitch_abs;
                        const src_row = src[src_off .. src_off + row_bytes];
                        const dst_off = row * cols;
                        const dst_row = alpha_storage[dst_off .. dst_off + cols];

                        for (0..cols) |col| {
                            const b = src_row[col / 2];
                            const shift: u3 = if ((col & 1) == 0) 4 else 0;
                            const v4: u8 = (b >> shift) & 0x0F;
                            dst_row[col] = @as(u8, v4 * 17);
                        }
                    }
                },
                .mono => {
                    const row_bytes = (cols + 7) / 8;
                    if (pitch_abs < row_bytes) return error.InvalidGlyphBitmapPitch;

                    for (0..rows) |row| {
                        const src_row_index = if (pitch_i32 >= 0) row else (rows - 1 - row);
                        const src_off = src_row_index * pitch_abs;
                        const src_row = src[src_off .. src_off + row_bytes];
                        const dst_off = row * cols;
                        const dst_row = alpha_storage[dst_off .. dst_off + cols];

                        for (0..cols) |col| {
                            const b = src_row[col / 8];
                            const mask: u8 = @as(u8, 0x80) >> @intCast(col & 7);
                            dst_row[col] = if ((b & mask) != 0) 255 else 0;
                        }
                    }
                },
                else => {
                    // Unsupported modes (lcd, bgra, etc): leave transparent fallback.
                    @memset(alpha_storage, 0);
                },
            }
        }

        defer if (alpha_storage.len > 0) self.allocator.free(alpha_storage);

        const inserted = self.cache.insert(
            key,
            alpha_storage,
            w,
            h,
            bearing_x,
            bearing_y,
            advance_x_26_6,
        ) catch |err| switch (err) {
            error.AtlasFull => blk: {
                self.cache.clear();

                break :blk try self.cache.insert(
                    key,
                    alpha_storage,
                    w,
                    h,
                    bearing_x,
                    bearing_y,
                    advance_x_26_6,
                );
            },
            else => return err,
        };

        return inserted;
    }

    fn pxSizeFromFloat(font_size: f32) !u32 {
        if (!std.math.isFinite(font_size) or font_size <= 0) return error.InvalidFontSize;
        return @intFromFloat(@max(1.0, @round(font_size)));
    }

    fn f26_6ToF32(v: i32) f32 {
        return @as(f32, @floatFromInt(v)) / 64.0;
    }
};
