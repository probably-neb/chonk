const std = @import("std");
const term = @import("term");
const base = @import("base");
const Arena = base.Arena;
const ui = @import("ui.zig");

const assert = std.debug.assert;

pub fn fill_events_from_raylib() void {
    const rl = @import("raylib");
    // TODO! use frame arena
    const scratch = Arena.get_scratch(&.{});
    defer scratch.release();

    const mouse_pos = rl.getMousePosition();
    const mouse_col: u16 = @truncate(@max(0, @as(i32, @intFromFloat(mouse_pos.x))));
    const mouse_row: u16 = @truncate(@max(0, @as(i32, @intFromFloat(mouse_pos.y))));
    const prev_mouse_pos = state.mouse_pos;
    state.mouse_pos = .{ mouse_col, mouse_row };

    const mods = Modifiers{
        .shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift),
        .alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt),
        .ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control),
    };

    if (mouse_col != prev_mouse_pos[0] or mouse_row != prev_mouse_pos[1]) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_move,
            .mods = mods,
            .mouse_button = .none,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }

    if (rl.isMouseButtonPressed(.left)) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_press,
            .mods = mods,
            .mouse_button = .left,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }
    if (rl.isMouseButtonReleased(.left)) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_release,
            .mods = mods,
            .mouse_button = .left,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }
    if (rl.isMouseButtonPressed(.middle)) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_press,
            .mods = mods,
            .mouse_button = .middle,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }
    if (rl.isMouseButtonReleased(.middle)) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_release,
            .mods = mods,
            .mouse_button = .middle,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }
    if (rl.isMouseButtonPressed(.right)) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_press,
            .mods = mods,
            .mouse_button = .right,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }
    if (rl.isMouseButtonReleased(.right)) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .mouse_release,
            .mods = mods,
            .mouse_button = .right,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{ 0, 0 },
        };
        state.events.append(ev);
    }

    const wheel = rl.getMouseWheelMoveV();
    if (wheel.x != 0 or wheel.y != 0) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .scroll,
            .mods = mods,
            .mouse_button = .none,
            .pos = .{ mouse_col, mouse_row },
            .scroll = .{
                @as(i16, @intFromFloat(-wheel.x)),
                @as(i16, @intFromFloat(wheel.y)),
            },
        };
        state.events.append(ev);
    }

    var codepoint = rl.getCharPressed();
    while (codepoint != 0) : (codepoint = rl.getCharPressed()) {
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .key_press,
            .key = .codepoint,
            .codepoint = @intCast(codepoint),
            .mods = mods,
        };
        state.events.append(ev);
    }

    var ray_key = rl.getKeyPressed();
    while (ray_key != .null) : (ray_key = rl.getKeyPressed()) {
        const key = switch (ray_key) {
            .escape => Key.escape,
            .enter, .kp_enter => Key.enter,
            .tab => Key.tab,
            .backspace => Key.backspace,
            .insert => Key.insert,
            .delete => Key.delete,
            .home => Key.home,
            .end => Key.end,
            .page_up => Key.page_up,
            .page_down => Key.page_down,
            .up => Key.up,
            .down => Key.down,
            .left => Key.left,
            .right => Key.right,
            .f1 => Key.f1,
            .f2 => Key.f2,
            .f3 => Key.f3,
            .f4 => Key.f4,
            .f5 => Key.f5,
            .f6 => Key.f6,
            .f7 => Key.f7,
            .f8 => Key.f8,
            .f9 => Key.f9,
            .f10 => Key.f10,
            .f11 => Key.f11,
            .f12 => Key.f12,
            else => continue,
        };
        const ev = scratch.arena.create(UiEvent) catch return;
        ev.* = .{
            .kind = .key_press,
            .key = key,
            .codepoint = 0,
            .mods = mods,
        };
        state.events.append(ev);
    }

    var event = state.events.first;
    while (event) |ev| {
        // std.debug.print("EVENT: {any}\n", .{ev});
        event = ev.next;
    }
}

// ---------------------------------------------------------------------------
// Event Types
// ---------------------------------------------------------------------------

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    _pad: u5 = 0,

    pub const none: Modifiers = .{};
};

pub const KeyEvent = struct {
    key: Key = .none,
    codepoint: u21 = 0,
    mods: Modifiers = .{},
};

pub const MouseKind = enum {
    press,
    release,
    move,
    scroll_up,
    scroll_down,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    none,
};

pub const MouseEvent = struct {
    kind: MouseKind = .press,
    button: MouseButton = .none,
    col: u16 = 0,
    row: u16 = 0,
    mods: Modifiers = .{},
};

pub const Event_Kind = enum {
    mouse_press,
    mouse_release,
    key_press,
    scroll,
    mouse_move,
};

pub const Key = enum {
    none,
    // printable mapped as codepoint
    codepoint,
    // special keys
    escape,
    enter,
    tab,
    backspace,
    insert,
    delete,
    home,
    end,
    page_up,
    page_down,
    up,
    down,
    left,
    right,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const UiEvent = struct {
    kind: Event_Kind = .key_press,
    key: Key = .none,
    codepoint: u21 = 0,
    mods: Modifiers = .{},
    mouse_button: MouseButton = .none,
    pos: [2]u16 = .{ 0, 0 },
    scroll: [2]i16 = .{ 0, 0 },
    consumed: bool = false,
    next: ?*UiEvent = null,
};

pub const UiEventList = struct {
    first: ?*UiEvent = null,
    last: ?*UiEvent = null,
    count: u32 = 0,

    fn append(list: *UiEventList, ev: *UiEvent) void {
        ev.next = null;
        if (list.last) |last| {
            last.next = ev;
        } else {
            list.first = ev;
        }
        list.last = ev;
        list.count += 1;
    }

    fn clear(list: *UiEventList) void {
        list.* = .{};
    }
};

// ---------------------------------------------------------------------------
// Interaction State
// ---------------------------------------------------------------------------

const InteractionState = struct {
    events: UiEventList = .{},
    mouse_pos: [2]u16 = .{ 0, 0 },
    hot_box_key: ui.Box_Key = ui.Box_Key.zero,
    active_box_key: [2]ui.Box_Key = .{ ui.Box_Key.zero, ui.Box_Key.zero },
    focus_hot_key: ui.Box_Key = ui.Box_Key.zero,
    focus_active_key: ui.Box_Key = ui.Box_Key.zero,
};

var state: InteractionState = .{};

// ---------------------------------------------------------------------------
// Public Getters
// ---------------------------------------------------------------------------

pub fn get_hot_box_key() ui.Box_Key {
    return state.hot_box_key;
}

pub fn get_focus_hot_key() ui.Box_Key {
    return state.focus_hot_key;
}

pub fn set_focus_hot_key(key: ui.Box_Key) void {
    state.focus_hot_key = key;
}

pub fn get_focus_active_key() ?ui.Box_Key {
    return if (state.focus_active_key.value == 0) null else state.focus_active_key;
}

pub fn get_mouse_pos() [2]u16 {
    return state.mouse_pos;
}

pub fn get_events() *UiEventList {
    return &state.events;
}

pub fn get_active_box_key(comptime button: enum { left, right }) ui.Box_Key {
    return state.active_box_key[
        switch (button) {
            .left => 0,
            .right => 1,
        }
    ];
}

// ---------------------------------------------------------------------------
// Frame Lifecycle
// ---------------------------------------------------------------------------

pub fn begin_frame() void {
    state.events.clear();
}

pub fn reset() void {
    state = .{};
}

// ---------------------------------------------------------------------------
// Event Processing (call after layout)
// ---------------------------------------------------------------------------

pub fn process_events(root: *ui.Box) void {
    update_hot_box(root);
    process_mouse_focus(root);
    process_focus_navigation(root);
}

fn update_hot_box(root: *ui.Box) void {
    var hot_pos = state.mouse_pos;
    var event_node = state.events.first;
    while (event_node) |event| : (event_node = event.next) {
        if (event.kind == .mouse_press) {
            hot_pos = event.pos;
            break;
        }
    }

    var result: ui.Box_Key = ui.Box_Key.zero;
    var current: ?*ui.Box = root;
    while (current) |box| {
        if (box.flags.clickable and !box.flags.disabled and
            box.rect.contains(hot_pos[0], hot_pos[1]))
        {
            result = box.key;
        }
        current = ui.tree_next(box);
    }
    state.hot_box_key = result;
}

fn process_mouse_focus(root: *ui.Box) void {
    var event_node = state.events.first;
    while (event_node) |event| : (event_node = event.next) {
        if (event.consumed) continue;
        if (event.kind != .mouse_press) continue;

        const clicked_key = find_topmost_focusable_at(root, event.pos[0], event.pos[1]);
        if (!clicked_key.is_zero()) {
            state.focus_hot_key = clicked_key;
        }
    }
}

fn find_topmost_focusable_at(root: *ui.Box, col: u16, row: u16) ui.Box_Key {
    var result: ui.Box_Key = ui.Box_Key.zero;
    var current: ?*ui.Box = root;
    while (current) |box| {
        if ((box.flags.focus_hot or box.flags.focus_active) and
            !box.flags.focus_nav_skip and !box.flags.disabled and
            !box.key.is_zero() and box.rect.contains(col, row))
        {
            result = box.key;
        }
        current = ui.tree_next(box);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Focus Navigation
// ---------------------------------------------------------------------------

const max_focusable = 256;

fn process_focus_navigation(root: *ui.Box) void {
    var focusable_keys: [max_focusable]ui.Box_Key = undefined;
    var focusable_count: u32 = 0;

    var current: ?*ui.Box = root;
    while (current) |box| {
        if ((box.flags.focus_hot or box.flags.focus_active) and
            !box.flags.focus_nav_skip and !box.flags.disabled and
            !box.key.is_zero())
        {
            if (focusable_count < max_focusable) {
                focusable_keys[focusable_count] = box.key;
                focusable_count += 1;
            }
        }
        current = ui.tree_next(box);
    }

    if (focusable_count == 0) {
        state.focus_hot_key = ui.Box_Key.zero;
        state.focus_active_key = ui.Box_Key.zero;
        return;
    }

    var current_idx: ?u32 = null;
    for (focusable_keys[0..focusable_count], 0..) |k, i| {
        if (k == state.focus_hot_key) {
            current_idx = @intCast(i);
            break;
        }
    }

    var event_node = state.events.first;
    while (event_node) |event| : (event_node = event.next) {
        if (event.consumed) continue;
        if (event.kind != .key_press or event.key != .tab) continue;

        if (event.mods.shift) {
            current_idx = if (current_idx) |idx|
                if (idx == 0) focusable_count - 1 else idx - 1
            else
                focusable_count - 1;
        } else {
            current_idx = if (current_idx) |idx|
                (idx + 1) % focusable_count
            else
                0;
        }
        event.consumed = true;
    }

    if (current_idx) |idx| {
        state.focus_hot_key = focusable_keys[idx];
    } else if (!state.focus_hot_key.is_zero()) {
        state.focus_hot_key = focusable_keys[0];
    }

    // focus_active follows focus_hot if the focused box has the focus_active flag
    state.focus_active_key = ui.Box_Key.zero;
    current = root;
    while (current) |box| {
        if (!box.key.is_zero() and box.key == state.focus_hot_key and box.flags.focus_active) {
            state.focus_active_key = box.key;
            break;
        }
        current = ui.tree_next(box);
    }
}

// ---------------------------------------------------------------------------
// Signal Computation
// ---------------------------------------------------------------------------

pub fn signal_from_box(box: *ui.Box) ui.Signal {
    var sig: ui.Signal = .{};

    if (box.flags.disabled or box.key.is_zero()) return sig;

    sig.mouse_pos = state.mouse_pos;

    const mouse_in_bounds = box.rect.contains(state.mouse_pos[0], state.mouse_pos[1]);

    if (mouse_in_bounds) sig.flags.mouse_over = true;
    if (mouse_in_bounds and box.flags.clickable and box.key == state.hot_box_key)
        sig.flags.hovering = true;

    // -- Mouse events -------------------------------------------------------
    var event_node = state.events.first;
    while (event_node) |event| : (event_node = event.next) {
        if (event.consumed) continue;

        switch (event.kind) {
            .mouse_press => {
                if (!box.flags.clickable) continue;
                const event_in_bounds = box.rect.contains(event.pos[0], event.pos[1]);
                if (!event_in_bounds) continue;
                if (box.key != state.hot_box_key) continue;

                if (event.mouse_button == .left) {
                    sig.flags.left_pressed = true;
                    state.active_box_key[0] = box.key;
                } else if (event.mouse_button == .right) {
                    sig.flags.right_pressed = true;
                    state.active_box_key[1] = box.key;
                }
                event.consumed = true;
            },
            .mouse_release => {
                const is_left = event.mouse_button == .left and
                    !state.active_box_key[0].is_zero() and
                    state.active_box_key[0] == box.key;
                const is_right = event.mouse_button == .right and
                    !state.active_box_key[1].is_zero() and
                    state.active_box_key[1] == box.key;

                if (is_left) {
                    sig.flags.left_released = true;
                    if (box.rect.contains(event.pos[0], event.pos[1]))
                        sig.flags.left_clicked = true;
                    state.active_box_key[0] = ui.Box_Key.zero;
                    event.consumed = true;
                }
                if (is_right) {
                    sig.flags.right_released = true;
                    if (box.rect.contains(event.pos[0], event.pos[1]))
                        sig.flags.right_clicked = true;
                    state.active_box_key[1] = ui.Box_Key.zero;
                    event.consumed = true;
                }
            },
            .scroll => {
                if (!box.flags.view_scroll) continue;
                if (!box.rect.contains(event.pos[0], event.pos[1])) continue;

                sig.scroll[0] +|= event.scroll[0];
                sig.scroll[1] +|= event.scroll[1];

                const scroll_speed: f32 = 3.0;
                box.view_off_target[0] += @as(f32, @floatFromInt(event.scroll[0])) * scroll_speed;
                box.view_off_target[1] += @as(f32, @floatFromInt(event.scroll[1])) * scroll_speed;

                event.consumed = true;
            },
            .key_press, .mouse_move => {},
        }
    }

    // -- Keyboard interaction via focus -------------------------------------
    if (box.flags.keyboard_clickable and state.focus_hot_key == box.key) {
        event_node = state.events.first;
        while (event_node) |event| : (event_node = event.next) {
            if (event.consumed) continue;
            if (event.kind != .key_press) continue;

            if (event.key == .enter or (event.key == .codepoint and event.codepoint == ' ')) {
                sig.flags.keyboard_pressed = true;
                sig.flags.commit = true;
                event.consumed = true;
            }
        }
    }

    // -- Keyboard scroll for view_scroll boxes with focus -------------------
    if (box.flags.view_scroll and !box.key.is_zero() and state.focus_hot_key == box.key) {
        const page_y: f32 = @floatFromInt(box.rect.h);
        event_node = state.events.first;
        while (event_node) |event| : (event_node = event.next) {
            if (event.consumed) continue;
            if (event.kind != .key_press) continue;

            switch (event.key) {
                .up => {
                    box.view_off_target[1] -= 1;
                    event.consumed = true;
                },
                .down => {
                    box.view_off_target[1] += 1;
                    event.consumed = true;
                },
                .page_up => {
                    box.view_off_target[1] -= page_y;
                    event.consumed = true;
                },
                .page_down => {
                    box.view_off_target[1] += page_y;
                    event.consumed = true;
                },
                .home => {
                    box.view_off_target[1] = 0;
                    event.consumed = true;
                },
                .end => {
                    box.view_off_target[1] = @max(0, box.view_bounds[1] - page_y);
                    event.consumed = true;
                },
                else => {},
            }
        }
    }

    // -- Clamp view_off_target to valid range -------------------------------
    if (box.flags.view_scroll) {
        const visible_w: f32 = @floatFromInt(box.rect.w);
        const visible_h: f32 = @floatFromInt(box.rect.h);
        box.view_off_target[0] = std.math.clamp(box.view_off_target[0], 0, @max(0, box.view_bounds[0] - visible_w));
        box.view_off_target[1] = std.math.clamp(box.view_off_target[1], 0, @max(0, box.view_bounds[1] - visible_h));
    }

    // -- Dragging -----------------------------------------------------------
    const is_active_left = !state.active_box_key[0].is_zero() and state.active_box_key[0] == box.key;
    const is_active_right = !state.active_box_key[1].is_zero() and state.active_box_key[1] == box.key;
    if (is_active_left or is_active_right) sig.flags.dragging = true;

    // -- Animate hot_t / active_t / focus_*_t -------------------------------
    const anim_rate: f32 = 15.0;
    const step = anim_rate * ui.get_dt();

    box.hot_t = animate(box.hot_t, sig.flags.hovering, step);
    box.active_t = animate(box.active_t, is_active_left or is_active_right, step);
    box.focus_hot_t = animate(box.focus_hot_t, state.focus_hot_key == box.key, step);
    box.focus_active_t = animate(box.focus_active_t, state.focus_active_key == box.key, step);
    box.disabled_t = animate(box.disabled_t, box.flags.disabled, step);

    const is_transitioning = (box.hot_t > 0.0 and box.hot_t < 1.0) or
        (box.active_t > 0.0 and box.active_t < 1.0) or
        (box.focus_hot_t > 0.0 and box.focus_hot_t < 1.0) or
        (box.focus_active_t > 0.0 and box.focus_active_t < 1.0) or
        (box.disabled_t > 0.0 and box.disabled_t < 1.0);
    if (is_transitioning) ui.set_animating();

    return sig;
}

fn animate(current: f32, target_on: bool, step: f32) f32 {
    return if (target_on)
        @min(1.0, current + step)
    else
        @max(0.0, current - step);
}
