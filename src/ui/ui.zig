const std = @import("std");
const base = @import("base");
const Arena = base.Arena;
const text = @import("text");

const assert = std.debug.assert;

pub const layout_mod = @import("layout.zig");
pub const interaction = @import("interaction.zig");
pub const draw_mod = @import("draw.zig");
pub const draw = draw_mod.draw;
pub const rl_color_from_arr = draw_mod.rl_color_from_arr;
pub const rl_color_to_arr = draw_mod.rl_color_to_arr;

// =============================
// TODO REMOVE
const DirEntry = @import("bin").DirEntry;
const clay = @import("clay");

pub const ClayCustom = union(enum) {
    none: void,
    squarified_treemap: struct {
        dir_entries: []const DirEntry,
    },

    pub const NONE: ClayCustom = .{ .none = {} };

    pub fn noneConfig() clay.ElementDeclaration {
        return .{ .custom = .{ .custom_data = @ptrCast(@constCast(&NONE)) } };
    }
};

pub inline fn ui_box(config: clay.ElementDeclaration) void {
    clay.cdefs.Clay__OpenElement();
    clay.cdefs.Clay__ConfigureOpenElement(config);
}

pub fn box_end() void {
    clay.cdefs.Clay__CloseElement();
}

// =============================

// ---------------------------------------------------------------------------
// Key
// ---------------------------------------------------------------------------

pub const Box_Key = packed struct(u64) {
    value: u64,

    pub const zero: Box_Key = .{ .value = 0 };

    pub fn from_string(seed: u64, string: []const u8) Box_Key {
        if (string.len == 0) return .{ .value = seed };
        const h = std.hash.Wyhash.hash(seed, string);
        return .{ .value = h };
    }

    // TODO: just replace with == .zero
    pub fn is_zero(key: Box_Key) bool {
        return key.value == 0;
    }

    pub fn hash(key: Box_Key) usize {
        return @truncate(key.value);
    }
};

pub const Tag = struct {
    display: []const u8,
    hash_string: []const u8,
    has_display_string: bool,
};

/// Splits a tagged string on `##` or `###` separators.
///
/// - `"text##hash_part"` → display = `"text"`, hash_string = `"hash_part"`
/// - `"text###anything"` → display = `"text"`, hash_string = `"text###anything"` (whole string)
/// - `"plain text"`      → display = `"plain text"`, hash_string = `"plain text"`
pub fn parse_tag(string: []const u8) Tag {
    if (find_separator(string)) |sep| {
        if (sep.is_triple) {
            return .{
                .display = string[0..sep.pos],
                .hash_string = string,
                .has_display_string = true,
            };
        }
        return .{
            .display = string[0..sep.pos],
            .hash_string = string[sep.pos + 2 ..],
            .has_display_string = true,
        };
    }
    return .{
        .display = string,
        .hash_string = string,
        .has_display_string = false,
    };
}

pub const Separator = struct {
    pos: usize,
    is_triple: bool,
};

pub fn find_separator(string: []const u8) ?Separator {
    if (string.len < 2) return null;
    var i: usize = 0;
    while (i + 1 < string.len) : (i += 1) {
        if (string[i] == '#' and string[i + 1] == '#') {
            const is_triple = (i + 2 < string.len and string[i + 2] == '#');
            return .{ .pos = i, .is_triple = is_triple };
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Axis / TextAlign
// ---------------------------------------------------------------------------

pub const Axis = enum(u1) {
    x = 0,
    y = 1,

    pub fn other(axis: Axis) Axis {
        return @enumFromInt(~@intFromEnum(axis));
    }
};

pub const TextAlign = enum {
    left,
    center,
    right,
};

// ---------------------------------------------------------------------------
// Size
// ---------------------------------------------------------------------------

pub const SizeKind = enum {
    null,
    pixels,
    text_content,
    parent_pct,
    children_sum,
};

pub const Size = struct {
    kind: SizeKind = .null,
    value: f32 = 0,
    strictness: f32 = 1,

    pub fn pixels(n: f32, strictness: f32) Size {
        return .{ .kind = .pixels, .value = n, .strictness = strictness };
    }

    pub fn text(pad: f32, strictness: f32) Size {
        return .{ .kind = .text_content, .value = pad, .strictness = strictness };
    }

    pub fn pct(frac: f32, strictness: f32) Size {
        return .{ .kind = .parent_pct, .value = frac, .strictness = strictness };
    }

    pub fn children(strictness: f32) Size {
        return .{ .kind = .children_sum, .value = 0, .strictness = strictness };
    }
};

// ---------------------------------------------------------------------------
// Rect
// ---------------------------------------------------------------------------

pub const Rect = struct {
    col: u16 = 0,
    row: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,

    pub fn contains(self: Rect, col: u16, row: u16) bool {
        return col >= self.col and col < self.col +| self.w and
            row >= self.row and row < self.row +| self.h;
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const a_right = a.col +| a.w;
        const a_bottom = a.row +| a.h;
        const b_right = b.col +| b.w;
        const b_bottom = b.row +| b.h;

        const left = @max(a.col, b.col);
        const top = @max(a.row, b.row);
        const right = @min(a_right, b_right);
        const bottom = @min(a_bottom, b_bottom);

        if (left >= right or top >= bottom) return .{};

        return .{
            .col = left,
            .row = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

// ---------------------------------------------------------------------------
// BoxFlags
// ---------------------------------------------------------------------------

pub const BoxFlags = packed struct(u32) {
    clickable: bool = false,
    keyboard_clickable: bool = false,
    view_scroll: bool = false,
    focus_hot: bool = false,
    focus_active: bool = false,

    draw_background: bool = false,
    draw_border: bool = false,
    draw_text: bool = false,
    draw_hot_effects: bool = false,
    draw_active_effects: bool = false,

    draw_side_top: bool = false,
    draw_side_bottom: bool = false,
    draw_side_left: bool = false,
    draw_side_right: bool = false,

    clip: bool = false,
    overflow_x: bool = false,
    overflow_y: bool = false,

    floating_x: bool = false,
    floating_y: bool = false,

    allow_overflow_x: bool = false,
    allow_overflow_y: bool = false,

    disabled: bool = false,
    focus_nav_skip: bool = false,
    has_display_string: bool = false,

    _pad: u8 = 0,

    pub fn with_border(self: BoxFlags) BoxFlags {
        var f = self;
        f.draw_border = true;
        f.draw_side_top = true;
        f.draw_side_bottom = true;
        f.draw_side_left = true;
        f.draw_side_right = true;
        return f;
    }

    pub fn merge(a: BoxFlags, b: BoxFlags) BoxFlags {
        const raw_a: u32 = @bitCast(a);
        const raw_b: u32 = @bitCast(b);
        return @bitCast(raw_a | raw_b);
    }
};

// ---------------------------------------------------------------------------
// Signal
// ---------------------------------------------------------------------------

pub const Signal = struct {
    flags: SignalFlags = .{},
    mouse_pos: [2]u16 = .{ 0, 0 },
    scroll: [2]i16 = .{ 0, 0 },

    pub fn clicked(signal: Signal) bool {
        return signal.flags.left_clicked or signal.flags.keyboard_pressed;
    }

    pub fn pressed(signal: Signal) bool {
        return signal.flags.left_pressed or signal.flags.keyboard_pressed;
    }

    pub fn released(signal: Signal) bool {
        return signal.flags.left_released;
    }

    pub fn hovering(signal: Signal) bool {
        return signal.flags.hovering;
    }

    pub fn dragging(signal: Signal) bool {
        return signal.flags.dragging;
    }
};

pub const SignalFlags = packed struct(u16) {
    left_pressed: bool = false,
    left_released: bool = false,
    left_clicked: bool = false,
    right_pressed: bool = false,
    right_released: bool = false,
    right_clicked: bool = false,
    keyboard_pressed: bool = false,
    hovering: bool = false,
    mouse_over: bool = false,
    dragging: bool = false,
    commit: bool = false,
    _pad: u5 = 0,

    pub fn any(flags: SignalFlags) bool {
        return @as(u16, @bitCast(flags)) & ~@as(u16, @bitCast(SignalFlags{ ._pad = 0b11111 })) != 0;
    }

    pub fn merge(a: SignalFlags, b: SignalFlags) SignalFlags {
        const raw_a: u16 = @bitCast(a);
        const raw_b: u16 = @bitCast(b);
        return @bitCast(raw_a | raw_b);
    }
};

const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub const default: Color = .rgba(.{ 0.0, 0.0, 0.0, 1.0 });

    pub fn to_rgba(c: Color) [4]f32 {
        return .{ c.r, c.g, c.b, c.a };
    }

    pub fn rgba(c: [4]f32) Color {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }

    pub fn to_rgba_vec(c: Color) @Vector(4, f32) {
        return .{ c.r, c.g, c.b, c.a };
    }

    pub fn rgba_vec(c: @Vector(4, f32)) Color {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.b and a.g == b.g and a.a == b.a;
    }
};

// ---------------------------------------------------------------------------
// Box
// ---------------------------------------------------------------------------

pub const Box = struct {
    // hash table links
    hash_next: ?*Box = null,
    hash_prev: ?*Box = null,

    // tree links
    first: ?*Box = null,
    last: ?*Box = null,
    next: ?*Box = null,
    prev: ?*Box = null,
    parent: ?*Box = null,
    child_count: u32 = 0,

    // identity & config (set during build)
    key: Box_Key = Box_Key.zero,
    flags: BoxFlags = .{},
    string: []const u8 = "",
    display_string: []const u8 = "",
    text_align: TextAlign = .left,
    // TODO: cache
    text_sizing: [2]f32 = .{ 0, 0 },
    text_spacing: f32 = 0.0,
    font_size: f32 = 0.0,
    pref_size: [2]Size = .{ .{}, .{} },
    child_layout_axis: Axis = .y,
    fixed_position: [2]f32 = .{ 0, 0 },
    fixed_size: [2]f32 = .{ 0, 0 },
    min_size: [2]f32 = .{ 0, 0 },

    // custom rendering callback
    custom_draw: ?*const fn (*Box, Rect) void = null,
    custom_draw_user_data: ?*anyopaque = null,

    // styling
    bg_color: Color = .default,
    fg_color: Color = .default,
    border_color: Color = .default,
    text_padding: u16 = 0,

    // computed by layout
    rect: Rect = .{},
    position_delta: [2]f32 = .{ 0, 0 },

    // persistent state (survives across frames)
    first_touched_build_index: u64 = 0,
    last_touched_build_index: u64 = 0,
    hot_t: f32 = 0,
    active_t: f32 = 0,
    disabled_t: f32 = 0,
    focus_hot_t: f32 = 0,
    focus_active_t: f32 = 0,
    view_off: [2]f32 = .{ 0, 0 },
    view_off_target: [2]f32 = .{ 0, 0 },
    view_bounds: [2]f32 = .{ 0, 0 },
};

pub fn push_child(parent_box: *Box, child: *Box) void {
    child.parent = parent_box;
    child.next = null;
    child.prev = parent_box.last;
    if (parent_box.last) |last| {
        last.next = child;
    } else {
        parent_box.first = child;
    }
    parent_box.last = child;
    parent_box.child_count += 1;
}

pub fn remove_child(child: *Box) void {
    const parent_box = child.parent orelse return;

    if (child.prev) |prev| {
        prev.next = child.next;
    } else {
        parent_box.first = child.next;
    }

    if (child.next) |next| {
        next.prev = child.prev;
    } else {
        parent_box.last = child.prev;
    }

    parent_box.child_count -= 1;
    child.parent = null;
    child.next = null;
    child.prev = null;
}

/// Depth-first pre-order traversal: returns the next box after `current`, or null.
pub fn tree_next(current: *Box) ?*Box {
    if (current.first) |first_child| return first_child;

    var node = current;
    while (true) {
        if (node.next) |sibling| return sibling;
        node = node.parent orelse return null;
    }
}

// ---------------------------------------------------------------------------
// Stack
// ---------------------------------------------------------------------------

pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        const max = 64;

        const Entry = struct { value: T, auto_pop: bool };

        entries: [max]Entry = undefined,
        len: u32 = 0,

        fn init(default: T) Self {
            var stack: Self = .{};
            stack.entries[0] = .{ .value = default, .auto_pop = false };
            stack.len = 1;
            return stack;
        }

        pub fn push(stack: *Self, value: T) T {
            const old = stack.top_val();
            assert(stack.len < max);
            stack.entries[stack.len] = .{ .value = value, .auto_pop = false };
            stack.len += 1;
            return old;
        }

        pub fn pop(stack: *Self) T {
            assert(stack.len > 1);
            stack.len -= 1;
            return stack.entries[stack.len].value;
        }

        pub fn top_val(stack: *const Self) T {
            return stack.entries[stack.len - 1].value;
        }

        pub fn set_next(stack: *Self, value: T) void {
            assert(stack.len < max);
            stack.entries[stack.len] = .{ .value = value, .auto_pop = true };
            stack.len += 1;
        }

        fn auto_pop_if_set(stack: *Self) void {
            if (stack.len > 1 and stack.entries[stack.len - 1].auto_pop) {
                stack.len -= 1;
            }
        }

        fn reset(stack: *Self) void {
            stack.len = 1;
        }
    };
}

// ---------------------------------------------------------------------------
// Stacks — declaration table & generated struct
// ---------------------------------------------------------------------------

const stack_decls = .{
    .{ "parent", ?*Box, @as(?*Box, null) },
    .{ "child_layout_axis", Axis, Axis.y },
    .{ "pref_width", Size, Size.pixels(10, 1) },
    .{ "pref_height", Size, Size.pixels(1, 1) },
    .{ "flags", BoxFlags, BoxFlags{} },
    .{ "bg_color", Color, Color.default },
    .{ "fg_color", Color, Color.default },
    .{ "border_color", Color, Color.default },
    .{ "text_padding", u16, @as(u16, 0) },
    .{ "text_spacing", f32, @as(f32, 0) },
    .{ "font_size", f32, @as(f32, 0) },
    .{ "text_align", TextAlign, TextAlign.left },
    .{ "fixed_x", f32, @as(f32, 0) },
    .{ "fixed_y", f32, @as(f32, 0) },
    .{ "fixed_width", f32, @as(f32, 0) },
    .{ "fixed_height", f32, @as(f32, 0) },
    .{ "min_width", f32, @as(f32, 0) },
    .{ "min_height", f32, @as(f32, 0) },
};

pub const Stacks = blk: {
    var fields: [stack_decls.len]std.builtin.Type.StructField = undefined;
    for (stack_decls, 0..) |decl, i| {
        const T = decl[1];
        const S = Stack(T);
        fields[i] = .{
            .name = decl[0],
            .type = S,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(S),
        };
    }
    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

fn init_stacks() Stacks {
    var s: Stacks = undefined;
    inline for (stack_decls) |decl| {
        @field(s, decl[0]) = Stack(decl[1]).init(decl[2]);
    }
    return s;
}

fn auto_pop_all(stacks: *Stacks) void {
    inline for (stack_decls) |decl| {
        @field(stacks, decl[0]).auto_pop_if_set();
    }
}

fn reset_stacks(stacks: *Stacks) void {
    inline for (stack_decls) |decl| {
        @field(stacks, decl[0]).reset();
    }
}

pub const StackName = std.meta.FieldEnum(Stacks);

fn StackValueType(comptime field: StackName) type {
    return @FieldType(Stacks, @tagName(field)).Value;
}

// ---------------------------------------------------------------------------
// Global State
// ---------------------------------------------------------------------------

const BOX_TABLE_SIZE = 4096;

const State = struct {
    arenas: [2]Arena = .{ Arena.zero, Arena.zero },
    arena_index: u1 = 0,
    build_index: u64 = 0,
    box_table: [BOX_TABLE_SIZE]?*Box = .{null} ** BOX_TABLE_SIZE,
    stacks: Stacks = undefined,
    root: ?*Box = null,
    screen_size: [2]u16 = .{ 0, 0 },
    active: bool = false,
    dt: f32 = 1.0 / 60.0,
    animating: bool = false,
};

var g: State = .{};

/// Full initialization — allocates two internal arenas for double-buffered
/// cross-frame box persistence. Call `deinit()` when done.
pub fn init_all() !void {
    g = .{};
    g.arenas[0] = try Arena.init(.{});
    g.arenas[1] = try Arena.init(.{});
    g.stacks = init_stacks();
    interaction.reset();
}

pub fn deinit() void {
    g.arenas[0].deinit();
    g.arenas[1].deinit();
    g = .{};
}

/// Lightweight init for tests that don't need cross-frame persistence.
/// Uses a single externally-owned arena. No hash table, no double buffering.
pub fn init(arena: *Arena) void {
    g = .{};
    g.arenas[0] = arena.*;
    g.stacks = init_stacks();
    g.active = true;
}

fn current_arena(self: *State) *Arena {
    return &self.arenas[self.arena_index];
}

pub fn get_build_arena() *Arena {
    return current_arena(&g);
}

/// Begin a new frame. clears the back buffer,
/// processes last frame's events, swaps arenas, and creates the root box.
pub fn begin_build(screen_w: u16, screen_h: u16, dt: f32) *Box {
    g.dt = dt;
    if (g.root) |prev_root| {
        interaction.process_events(prev_root);
    }

    g.build_index += 1;
    g.arena_index ^= 1;
    g.arenas[g.arena_index].clear();
    g.stacks = init_stacks();
    g.screen_size = .{ screen_w, screen_h };
    g.animating = false;
    g.active = true;

    const root_box = build_box("root###", .{});
    root_box.pref_size = .{ Size.cells(@floatFromInt(screen_w), 1), Size.cells(@floatFromInt(screen_h), 1) };
    root_box.fixed_size = .{ @floatFromInt(screen_w), @floatFromInt(screen_h) };
    push_parent(root_box);
    g.root = root_box;
    return root_box;
}

/// Finish the frame: run layout, animate floats, prune stale boxes.
pub fn end_build() void {
    // TODO: just assert not null
    if (g.root) |r| {
        layout_mod.layout(r, g.screen_size[0], g.screen_size[1]);
    }
    // prune stale boxes that were not touched in this build
    // TODO: better function name
    prune_box_table();
    g.active = false;
}

/// Return the root box of the current frame (set by `begin_build`).
pub fn get_root() ?*Box {
    return g.root;
}

pub fn get_dt() f32 {
    return g.dt;
}

pub fn set_animating() void {
    g.animating = true;
}

pub fn is_animating() bool {
    return g.animating;
}

fn box_table_slot(key: Box_Key) usize {
    return key.hash() & (BOX_TABLE_SIZE - 1);
}

fn box_table_lookup(key: Box_Key) ?*Box {
    const slot = box_table_slot(key);
    var node = g.box_table[slot];
    while (node) |n| {
        if (n.key == key) return n;
        node = n.hash_next;
    }
    return null;
}

fn box_table_insert(b: *Box) void {
    const slot = box_table_slot(b.key);
    b.hash_next = g.box_table[slot];
    b.hash_prev = null;
    if (g.box_table[slot]) |head| {
        head.hash_prev = b;
    }
    g.box_table[slot] = b;
}

fn box_table_remove(b: *Box) void {
    const slot = box_table_slot(b.key);
    if (b.hash_prev) |prev| {
        prev.hash_next = b.hash_next;
    } else {
        g.box_table[slot] = b.hash_next;
    }
    if (b.hash_next) |next| {
        next.hash_prev = b.hash_prev;
    }
    b.hash_next = null;
    b.hash_prev = null;
}

fn prune_box_table() void {
    for (&g.box_table) |*slot| {
        var node = slot.*;
        while (node) |n| {
            const next = n.hash_next;
            if (n.last_touched_build_index < g.build_index) {
                box_table_remove(n);
            }
            node = next;
        }
    }
}

// -- Generic interface ------------------------------------------------------

pub fn push_stack(comptime field: StackName, value: StackValueType(field)) StackValueType(field) {
    return @field(&g.stacks, @tagName(field)).push(value);
}

pub fn pop_stack(comptime field: StackName) StackValueType(field) {
    return @field(&g.stacks, @tagName(field)).pop();
}

pub fn top_stack(comptime field: StackName) StackValueType(field) {
    return @field(&g.stacks, @tagName(field)).top_val();
}

pub fn set_next_stack(comptime field: StackName, value: StackValueType(field)) void {
    @field(&g.stacks, @tagName(field)).set_next(value);
}

// -- Named helpers: parent --------------------------------------------------

pub fn push_parent(b: *Box) void {
    _ = push_stack(.parent, b);
}

pub fn pop_parent() void {
    _ = pop_stack(.parent);
}

// -- Persistent push/pop helpers --------------------------------------------

pub fn push_axis(v: Axis) void {
    _ = push_stack(.child_layout_axis, v);
}
pub fn pop_axis() void {
    _ = pop_stack(.child_layout_axis);
}

pub fn push_width(v: Size) void {
    _ = push_stack(.pref_width, v);
}
pub fn pop_width() void {
    _ = pop_stack(.pref_width);
}

pub fn push_height(v: Size) void {
    _ = push_stack(.pref_height, v);
}
pub fn pop_height() void {
    _ = pop_stack(.pref_height);
}

pub fn push_flags(v: BoxFlags) void {
    _ = push_stack(.flags, v);
}
pub fn pop_flags() void {
    _ = pop_stack(.flags);
}

pub fn push_color(v: Color) void {
    _ = push_stack(.fg_color, v);
}
pub fn pop_color() void {
    _ = pop_stack(.fg_color);
}

pub fn push_bg(v: Color) void {
    _ = push_stack(.bg_color, v);
}
pub fn pop_bg() void {
    _ = pop_stack(.bg_color);
}

pub fn push_border_color(v: Color) void {
    _ = push_stack(.border_color, v);
}
pub fn pop_border_color() void {
    _ = pop_stack(.border_color);
}

pub fn push_text_padding(v: u16) void {
    _ = push_stack(.text_padding, v);
}
pub fn pop_text_padding() void {
    _ = pop_stack(.text_padding);
}

pub fn push_text_align(v: TextAlign) void {
    _ = push_stack(.text_align, v);
}
pub fn pop_text_align() void {
    _ = pop_stack(.text_align);
}

// -- Auto-pop helpers (consumed by next build_box) --------------------------

pub fn next_axis(v: Axis) void {
    set_next_stack(.child_layout_axis, v);
}

pub fn next_width(v: Size) void {
    set_next_stack(.pref_width, v);
}

pub fn next_height(v: Size) void {
    set_next_stack(.pref_height, v);
}

pub fn next_size(w: Size, h: Size) void {
    set_next_stack(.pref_width, w);
    set_next_stack(.pref_height, h);
}

pub fn next_flags(v: BoxFlags) void {
    set_next_stack(.flags, v);
}

pub fn next_color(v: Color) void {
    set_next_stack(.fg_color, v);
}

pub fn next_bg(v: Color) void {
    set_next_stack(.bg_color, v);
}

pub fn next_border_color(v: Color) void {
    set_next_stack(.border_color, v);
}

pub fn next_text_padding(v: u16) void {
    set_next_stack(.text_padding, v);
}

pub fn next_text_align(v: TextAlign) void {
    set_next_stack(.text_align, v);
}

pub fn next_fixed_x(v: f32) void {
    set_next_stack(.fixed_x, v);
}

pub fn next_fixed_y(v: f32) void {
    set_next_stack(.fixed_y, v);
}

pub fn next_fixed_width(v: f32) void {
    set_next_stack(.fixed_width, v);
}

pub fn next_fixed_height(v: f32) void {
    set_next_stack(.fixed_height, v);
}

pub fn next_min_width(v: f32) void {
    set_next_stack(.min_width, v);
}

pub fn next_min_height(v: f32) void {
    set_next_stack(.min_height, v);
}

// -- Box construction -------------------------------------------------------

pub fn build_box(string: []const u8, extra_flags: BoxFlags) *Box {
    const arena = current_arena(&g);
    const box = arena.create(Box) catch @panic("OOM: build_box");
    box.* = .{};

    const tag = parse_tag(string);
    box.string = string;
    box.display_string = tag.display;

    const parent_box = top_stack(.parent);
    const seed: u64 = if (parent_box) |p| p.key.value else 0;
    box.key = Box_Key.from_string(seed, tag.hash_string);

    const old = if (!box.key.is_zero()) box_table_lookup(box.key) else null;
    if (old) |prev| {
        box.first_touched_build_index = prev.first_touched_build_index;
        box.hot_t = prev.hot_t;
        box.active_t = prev.active_t;
        box.disabled_t = prev.disabled_t;
        box.focus_hot_t = prev.focus_hot_t;
        box.focus_active_t = prev.focus_active_t;
        box.view_off = prev.view_off;
        box.view_off_target = prev.view_off_target;
        box.view_bounds = prev.view_bounds;
        box.position_delta = .{
            @as(f32, @floatFromInt(box.rect.col)) - @as(f32, @floatFromInt(prev.rect.col)),
            @as(f32, @floatFromInt(box.rect.row)) - @as(f32, @floatFromInt(prev.rect.row)),
        };
        box.rect = prev.rect;
        box_table_remove(prev);
    } else {
        box.first_touched_build_index = g.build_index;
    }
    box.last_touched_build_index = g.build_index;

    box.flags = BoxFlags.merge(top_stack(.flags), extra_flags);
    if (tag.has_display_string) box.flags.has_display_string = true;
    box.child_layout_axis = top_stack(.child_layout_axis);
    box.pref_size = .{ top_stack(.pref_width), top_stack(.pref_height) };
    box.bg_color = top_stack(.bg_color);
    box.fg_color = top_stack(.fg_color);
    box.border_color = top_stack(.border_color);
    box.text_padding = top_stack(.text_padding);
    box.text_align = top_stack(.text_align);
    box.fixed_position = .{ top_stack(.fixed_x), top_stack(.fixed_y) };
    box.fixed_size = .{ top_stack(.fixed_width), top_stack(.fixed_height) };
    box.min_size = .{ top_stack(.min_width), top_stack(.min_height) };
    box.text_spacing = top_stack(.text_spacing);
    box.font_size = top_stack(.font_size);

    const text_size = text.measure_text(tag.display, box.font_size, box.text_spacing);
    box.text_sizing = .{ text_size.x, text_size.y };

    if (!box.key.is_zero()) {
        box_table_insert(box);
    }

    if (parent_box) |p| push_child(p, box);

    auto_pop_all(&g.stacks);

    return box;
}

/// Build a box and push it as the current parent.
/// Caller must call `pop_parent()` when done adding children.
pub fn push_parent_box(string: []const u8, extra_flags: BoxFlags) *Box {
    const b = build_box(string, extra_flags);
    push_parent(b);
    return b;
}

pub fn spacer(comptime axis: Axis, amount: f32) void {
    switch (axis) {
        .x => {
            next_width(.cells(amount, 1));
            next_height(.cells(1, 1));
        },
        .y => {
            next_width(.pct(1, 0));
            next_height(.cells(amount, 1));
        },
    }
    _ = build_box("", .{});
}

// ---------------------------------------------------------------------------
// Signal Convenience Helpers
// ---------------------------------------------------------------------------

pub fn signal_from_box(box: *Box) Signal {
    return interaction.signal_from_box(box);
}

pub fn clicked(sig: Signal) bool {
    return sig.clicked();
}

pub fn pressed(sig: Signal) bool {
    return sig.pressed();
}

pub fn released(sig: Signal) bool {
    return sig.released();
}

pub fn arena_dupe(src: []const u8) ![]const u8 {
    const arena = current_arena(&g);
    return arena.dupe(u8, src);
}

pub fn arena_print(comptime fmt: []const u8, args: anytype) ![]const u8 {
    const arena = current_arena(&g);
    // TODO: duplicate alloc print into a `print` function on base.Arena itself
    return std.fmt.allocPrint(arena.allocator(), fmt, args);
}

// ---------------------------------------------------------------------------
// Custom draw data helper
// ---------------------------------------------------------------------------

/// Bidirectional cast for `custom_draw_user_data`.
///
///   // Storing — typed pointer → *anyopaque:
///   box.custom_draw_user_data = custom_draw_data(f32, &app.progress);
///
///   // Reading — *anyopaque → typed pointer:
///   const ptr = custom_draw_data(f32, box.custom_draw_user_data) orelse return;
pub fn custom_draw_data(comptime T: type, value: anytype) Custom_Draw_Data(T, @TypeOf(value)) {
    const V = @TypeOf(value);
    if (V == ?*anyopaque) {
        return if (value) |ptr| @ptrCast(@alignCast(ptr)) else null;
    } else if (V == *anyopaque) {
        return @ptrCast(@alignCast(value));
    } else {
        return @ptrCast(@constCast(value));
    }
}

fn Custom_Draw_Data(comptime T: type, comptime V: type) type {
    if (V == ?*anyopaque) return ?*T;
    if (V == *anyopaque) return *T;
    return *anyopaque;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "Stack push/pop/top" {
    var s = Stack(i32).init(0);
    try std.testing.expectEqual(@as(i32, 0), s.top_val());
    _ = s.push(10);
    try std.testing.expectEqual(@as(i32, 10), s.top_val());
    _ = s.push(20);
    const popped = s.pop();
    try std.testing.expectEqual(@as(i32, 20), popped);
    try std.testing.expectEqual(@as(i32, 10), s.top_val());
}

test "Stack set_next auto-pops" {
    var s = Stack(i32).init(0);
    s.set_next(42);
    try std.testing.expectEqual(@as(i32, 42), s.top_val());
    s.auto_pop_if_set();
    try std.testing.expectEqual(@as(i32, 0), s.top_val());
}

test "build_box applies stack tops and auto-pops set_next" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    init(&arena);

    push_bg(.default);
    next_width(.pixels(20, 1));
    next_height(.pixels(3, 1));

    const b = build_box("hello", .{ .draw_text = true });
    try std.testing.expect(b.flags.draw_text);
    try std.testing.expect(Color.eql(b.bg_color, .default));
    try std.testing.expectEqual(@as(f32, 20), b.pref_size[0].value);

    // set_next values should be gone, push values remain
    try std.testing.expect(Color.eql(top_stack(.bg_color), .{ .ansi = .red }));
    try std.testing.expectEqual(Size.pixels(10, 1).value, top_stack(.pref_width).value);
}

test "push_parent_box links children" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    init(&arena);

    const r = push_parent_box("root", .{});
    _ = build_box("child1", .{});
    _ = build_box("child2", .{});
    pop_parent();

    try std.testing.expectEqual(@as(u32, 2), r.child_count);
    try std.testing.expectEqualStrings("child1", r.first.?.string);
    try std.testing.expectEqualStrings("child2", r.last.?.string);
}

test "parse_tag separators" {
    const dbl = parse_tag("Click Me##button_id");
    try std.testing.expectEqualStrings("Click Me", dbl.display);
    try std.testing.expectEqualStrings("button_id", dbl.hash_string);
    try std.testing.expect(dbl.has_display_string);

    const tri = parse_tag("Click Me###unique");
    try std.testing.expectEqualStrings("Click Me", tri.display);
    try std.testing.expectEqualStrings("Click Me###unique", tri.hash_string);
}

test "Rect intersect" {
    const i = Rect.intersect(
        .{ .col = 0, .row = 0, .w = 10, .h = 10 },
        .{ .col = 5, .row = 5, .w = 10, .h = 10 },
    );
    try std.testing.expectEqual(@as(u16, 5), i.col);
    try std.testing.expectEqual(@as(u16, 5), i.w);

    const none = Rect.intersect(
        .{ .col = 0, .row = 0, .w = 5, .h = 5 },
        .{ .col = 10, .row = 10, .w = 5, .h = 5 },
    );
    try std.testing.expectEqual(@as(u16, 0), none.w);
}

test "cross-frame persistence via begin_build/end_build" {
    try init_all();
    defer deinit();

    // Frame 1: build a box with a known key
    _ = begin_build(80, 24, 1.0 / 60.0);
    const b1 = build_box("persist_me##stable_key", .{ .draw_text = true });
    b1.hot_t = 0.75;
    b1.view_off = .{ 10, 20 };
    const key1 = b1.key;
    end_build();

    // Frame 2: build the same key — persistent fields should carry over
    _ = begin_build(80, 24, 1.0 / 60.0);
    const b2 = build_box("persist_me##stable_key", .{ .draw_text = true });
    try std.testing.expect(b2.key == key1);
    try std.testing.expectEqual(@as(f32, 0.75), b2.hot_t);
    try std.testing.expectEqual(@as(f32, 10), b2.view_off[0]);
    try std.testing.expectEqual(@as(f32, 20), b2.view_off[1]);
    end_build();
}

test "stale boxes are pruned from hash table" {
    try init_all();
    defer deinit();

    // Frame 1: build a box
    _ = begin_build(80, 24, 1.0 / 60.0);
    const b1 = build_box("ephemeral##gone", .{});
    const key = b1.key;
    end_build();

    // Frame 2: do NOT build that box
    _ = begin_build(80, 24, 1.0 / 60.0);
    end_build();

    // The old box should have been pruned
    try std.testing.expect(box_table_lookup(key) == null);
}

test "begin_build creates root and end_build runs layout" {
    try init_all();
    defer deinit();

    _ = begin_build(80, 24, 1.0 / 60.0);

    next_width(Size.pixels(40, 1));
    next_height(Size.pixels(5, 1));
    _ = build_box("child##c1", .{});

    end_build();

    const r = get_root().?;
    try std.testing.expectEqual(@as(u16, 80), r.rect.w);
    try std.testing.expectEqual(@as(u16, 24), r.rect.h);

    const child = r.first.?;
    try std.testing.expectEqual(@as(u16, 40), child.rect.w);
    try std.testing.expectEqual(@as(u16, 5), child.rect.h);
}
