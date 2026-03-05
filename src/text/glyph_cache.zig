const std = @import("std");
const rl = @import("raylib");

pub const GlyphKey = struct {
    glyph_id: u32,
    pixel_size: u32,
};

pub const GlyphEntry = struct {
    key: GlyphKey,

    // Atlas placement
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    // FreeType metrics (pixel space)
    bearing_x: i32,
    bearing_y: i32,
    advance_x_26_6: i32,
};

pub const GlyphCache = struct {
    const Rect = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    };

    allocator: std.mem.Allocator,
    atlas: rl.Texture2D,
    atlas_w: i32,
    atlas_h: i32,

    entries: std.ArrayListUnmanaged(GlyphEntry) = .{},
    map: std.AutoHashMapUnmanaged(u64, usize) = .{},
    clear_scratch_rgba: []u8,

    // Row packer state
    pen_x: i32 = 0,
    pen_y: i32 = 0,
    row_h: i32 = 0,

    const pad: i32 = 1;

    pub fn init(
        allocator: std.mem.Allocator,
        atlas_w: i32,
        atlas_h: i32,
    ) !GlyphCache {
        const zero_pixels = try allocator.alloc(u8, @as(usize, @intCast(atlas_w * atlas_h * 4)));
        defer allocator.free(zero_pixels);
        @memset(zero_pixels, 0);

        const image: rl.Image = .{
            .data = zero_pixels.ptr,
            .width = atlas_w,
            .height = atlas_h,
            .mipmaps = 1,
            .format = rl.PixelFormat.uncompressed_r8g8b8a8,
        };

        const atlas = try rl.loadTextureFromImage(image);
        rl.setTextureFilter(atlas, .bilinear);

        const clear_scratch_rgba = allocator.alloc(u8, @as(usize, @intCast(atlas_w * atlas_h * 4))) catch {
            rl.unloadTexture(atlas);
            return error.OutOfMemory;
        };
        @memset(clear_scratch_rgba, 0);

        return .{
            .allocator = allocator,
            .atlas = atlas,
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .clear_scratch_rgba = clear_scratch_rgba,
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        self.entries.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.allocator.free(self.clear_scratch_rgba);
        rl.unloadTexture(self.atlas);
        self.* = undefined;
    }

    pub fn clear(self: *GlyphCache) void {
        self.entries.clearRetainingCapacity();
        self.map.clearRetainingCapacity();

        self.pen_x = 0;
        self.pen_y = 0;
        self.row_h = 0;

        @memset(self.clear_scratch_rgba, 0);
        rl.updateTexture(self.atlas, self.clear_scratch_rgba.ptr);
    }

    pub fn lookup(self: *GlyphCache, key: GlyphKey) ?*const GlyphEntry {
        const idx = self.map.get(hashKey(key)) orelse return null;
        return &self.entries.items[idx];
    }

    pub fn insert(
        self: *GlyphCache,
        key: GlyphKey,
        alpha_bitmap: []const u8,
        bmp_w: i32,
        bmp_h: i32,
        bearing_x: i32,
        bearing_y: i32,
        advance_x_26_6: i32,
    ) !*const GlyphEntry {
        var rect_x: i32 = 0;
        var rect_y: i32 = 0;
        var rect_w: i32 = bmp_w;
        var rect_h: i32 = bmp_h;

        if ((bmp_w == 0) != (bmp_h == 0)) return error.InvalidGlyphBitmap;
        if (bmp_w < 0 or bmp_h < 0) return error.InvalidGlyphBitmap;

        if (bmp_w > 0 and bmp_h > 0) {
            const px_count_i64 = @as(i64, bmp_w) * @as(i64, bmp_h);
            if (px_count_i64 <= 0) return error.InvalidGlyphBitmap;

            const expected: usize = @intCast(px_count_i64);
            if (alpha_bitmap.len != expected) return error.InvalidGlyphBitmapBuffer;
            const src_alpha = alpha_bitmap[0..expected];

            const rect = try self.allocRect(bmp_w, bmp_h);
            rect_x = rect.x;
            rect_y = rect.y;
            rect_w = rect.w;
            rect_h = rect.h;

            if (rect_w != bmp_w or rect_h != bmp_h) return error.InvalidAtlasRect;
            if (rect_x < 0 or rect_y < 0) return error.InvalidAtlasRect;
            if (rect_x + rect_w > self.atlas_w or rect_y + rect_h > self.atlas_h) return error.InvalidAtlasRect;

            var rgba = try self.allocator.alloc(u8, expected * 4);
            defer self.allocator.free(rgba);

            for (src_alpha, 0..) |a, i| {
                const base = i * 4;
                rgba[base + 0] = 255;
                rgba[base + 1] = 255;
                rgba[base + 2] = 255;
                rgba[base + 3] = a;
            }

            rl.updateTextureRec(
                self.atlas,
                .{
                    .x = @floatFromInt(rect_x),
                    .y = @floatFromInt(rect_y),
                    .width = @floatFromInt(rect_w),
                    .height = @floatFromInt(rect_h),
                },
                rgba.ptr,
            );
        }

        const entry = GlyphEntry{
            .key = key,
            .x = rect_x,
            .y = rect_y,
            .w = rect_w,
            .h = rect_h,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .advance_x_26_6 = advance_x_26_6,
        };

        try self.entries.append(self.allocator, entry);
        const idx = self.entries.items.len - 1;
        try self.map.put(self.allocator, hashKey(key), idx);
        return &self.entries.items[idx];
    }

    fn allocRect(self: *GlyphCache, w: i32, h: i32) !Rect {
        if (w <= 0 or h <= 0) return error.InvalidGlyphBitmap;

        if (self.pen_x + w + pad > self.atlas_w) {
            self.pen_x = 0;
            self.pen_y += self.row_h + pad;
            self.row_h = 0;
        }

        if (self.pen_y + h + pad > self.atlas_h) {
            return error.AtlasFull;
        }

        const out: Rect = .{ .x = self.pen_x, .y = self.pen_y, .w = w, .h = h };

        self.pen_x += w + pad;
        if (h > self.row_h) self.row_h = h;

        return out;
    }

    fn hashKey(key: GlyphKey) u64 {
        return (@as(u64, key.glyph_id) << 32) | @as(u64, key.pixel_size);
    }
};
