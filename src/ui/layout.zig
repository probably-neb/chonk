const std = @import("std");
const ui = @import("ui.zig");
const draw = @import("term").draw;
const Box = ui.Box;
const Axis = ui.Axis;
const Size = ui.Size;
const SizeKind = ui.SizeKind;
const Rect = ui.Rect;
const BoxFlags = ui.BoxFlags;

/// Run the full layout algorithm on a box tree rooted at `root`.
/// Sets `root.rect` to the screen bounds, then runs all 5 passes
/// for X, then all 5 passes for Y.
pub fn layout(root: *Box, screen_w: u16, screen_h: u16) void {
    root.rect = .{ .col = 0, .row = 0, .w = screen_w, .h = screen_h };
    root.fixed_size = .{ @floatFromInt(screen_w), @floatFromInt(screen_h) };

    layout_axis(root, .x);
    layout_axis(root, .y);
}

fn layout_axis(root: *Box, comptime axis: Axis) void {
    pass_standalone(root, axis);
    pass_upwards_dependent(root, axis);
    pass_downwards_dependent(root, axis);
    pass_constraints(root, axis);
    pass_position(root, axis);
}

// -----------------------------------------------------------------------
// Pass 1: Standalone Sizes (cells, text_content)
// -----------------------------------------------------------------------

fn pass_standalone(root: *Box, comptime axis: Axis) void {
    var current: ?*Box = root.first;
    while (current) |box| {
        resolve_standalone(box, axis);
        current = tree_next_within(box, root);
    }
}

fn resolve_standalone(box: *Box, comptime axis: Axis) void {
    const axis_index = @intFromEnum(axis);
    const size = box.pref_size[axis_index];
    switch (size.kind) {
        .cells => box.fixed_size[axis_index] = size.value,
        .text_content => {
            if (axis == .x) {
                const text_len: f32 = @floatFromInt(display_width(box.display_string));
                box.fixed_size[axis_index] = text_len + size.value + @as(f32, @floatFromInt(box.text_padding)) * 2;
            } else {
                box.fixed_size[axis_index] = 1 + size.value;
            }
        },
        else => {},
    }
}

// -----------------------------------------------------------------------
// Pass 2: Upwards-Dependent Sizes (parent_pct)
// -----------------------------------------------------------------------

fn pass_upwards_dependent(root: *Box, comptime axis: Axis) void {
    var current: ?*Box = root.first;
    while (current) |box| {
        resolve_upwards(box, axis);
        current = tree_next_within(box, root);
    }
}

fn resolve_upwards(box: *Box, comptime axis: Axis) void {
    const axis_index = @intFromEnum(axis);
    if (box.pref_size[axis_index].kind != .parent_pct) return;

    const frac = box.pref_size[axis_index].value;
    const avail = ancestor_resolved_size(box, axis);
    box.fixed_size[axis_index] = @round(avail * frac);
}

fn ancestor_resolved_size(box: *Box, comptime axis: Axis) f32 {
    const axis_index = @intFromEnum(axis);
    var parent = box.parent;
    while (parent) |ancestor| {
        const kind = ancestor.pref_size[axis_index].kind;
        if (kind == .cells or kind == .text_content or kind == .null) {
            const insets = border_insets(ancestor);
            return @max(ancestor.fixed_size[axis_index] - insets.before[axis_index] - insets.after[axis_index], 0);
        }
        if (kind == .parent_pct and ancestor.fixed_size[axis_index] > 0) {
            const insets = border_insets(ancestor);
            return @max(ancestor.fixed_size[axis_index] - insets.before[axis_index] - insets.after[axis_index], 0);
        }
        // A children_sum ancestor's size is defined by its children, so
        // resolving against it (or any ancestor above it) creates a
        // circular dependency that inflates the children_sum container.
        // Return 0 and let the position pass fill cross-axis children
        // to the available space once children_sum is known.
        // Note: raddebugger walks past children_sum here, but their
        // position pass has no "fill to available" cross-axis logic,
        // so they don't use parent_pct for cross-axis fill in
        // children_sum containers the way we do.
        if (kind == .children_sum) return 0;
        parent = ancestor.parent;
    }
    return 0;
}

// -----------------------------------------------------------------------
// Pass 3: Downwards-Dependent Sizes (children_sum) — post-order
// -----------------------------------------------------------------------

fn pass_downwards_dependent(root: *Box, comptime axis: Axis) void {
    post_order_walk(root, axis);
}

fn post_order_walk(node: *Box, comptime axis: Axis) void {
    var next_child = node.first;
    while (next_child) |child| {
        post_order_walk(child, axis);
        next_child = child.next;
    }
    resolve_downwards(node, axis);
}

fn resolve_downwards(box: *Box, comptime axis: Axis) void {
    const axis_index = @intFromEnum(axis);
    if (box.pref_size[axis_index].kind != .children_sum) return;

    const insets = border_insets(box);

    if (axis == box.child_layout_axis) {
        var sum: f32 = 0;
        var next_child = box.first;
        while (next_child) |child| {
            if (!is_floating(child, axis)) {
                sum += child.fixed_size[axis_index];
            }
            next_child = child.next;
        }
        box.fixed_size[axis_index] = sum + insets.before[axis_index] + insets.after[axis_index];
    } else {
        var max_cross: f32 = 0;
        var next_child = box.first;
        while (next_child) |child| {
            if (!is_floating(child, axis)) {
                max_cross = @max(max_cross, child.fixed_size[axis_index]);
            }
            next_child = child.next;
        }
        box.fixed_size[axis_index] = max_cross + insets.before[axis_index] + insets.after[axis_index];
    }
}

// -----------------------------------------------------------------------
// Pass 4: Constraint Enforcement
// -----------------------------------------------------------------------

fn pass_constraints(root: *Box, comptime axis: Axis) void {
    constrain_subtree(root, axis);
}

fn constrain_subtree(parent: *Box, comptime axis: Axis) void {
    const axis_index = @intFromEnum(axis);
    const insets = border_insets(parent);
    const avail = @max(parent.fixed_size[axis_index] - insets.before[axis_index] - insets.after[axis_index], 0);
    const allow_overflow = if (axis == .x) parent.flags.allow_overflow_x else parent.flags.allow_overflow_y;

    if (!allow_overflow) {
        if (axis == parent.child_layout_axis) {
            constrain_layout_axis(parent, axis, avail);
        } else {
            constrain_cross_axis(parent, axis, avail);
        }
    }

    // When a parent allows overflow, its size is now finalized —
    // re-resolve ParentPct children against it.
    if (allow_overflow) {
        var next_child = parent.first;
        while (next_child) |child| {
            if (child.pref_size[axis_index].kind == .parent_pct) {
                child.fixed_size[axis_index] = avail * child.pref_size[axis_index].value;
            }
            next_child = child.next;
        }
    }

    // Enforce min_size.
    {
        var next_child = parent.first;
        while (next_child) |child| {
            child.fixed_size[axis_index] = @max(child.fixed_size[axis_index], child.min_size[axis_index]);
            next_child = child.next;
        }
    }

    var next_child = parent.first;
    while (next_child) |child| {
        constrain_subtree(child, axis);
        next_child = child.next;
    }
}

fn constrain_layout_axis(parent: *Box, comptime axis: Axis, avail: f32) void {
    const axis_index = @intFromEnum(axis);
    var total: f32 = 0;
    var total_weighted: f32 = 0;

    var next_child = parent.first;
    while (next_child) |child| {
        if (!is_floating(child, axis)) {
            total += child.fixed_size[axis_index];
            total_weighted += child.fixed_size[axis_index] * (1.0 - child.pref_size[axis_index].strictness);
        }
        next_child = child.next;
    }

    const violation = total - avail;
    if (violation <= 0 or total_weighted <= 0) return;

    const fixup_pct = @min(violation / total_weighted, 1.0);

    next_child = parent.first;
    while (next_child) |child| {
        if (!is_floating(child, axis)) {
            const fixup = @max(child.fixed_size[axis_index] * (1.0 - child.pref_size[axis_index].strictness), 0);
            child.fixed_size[axis_index] -= fixup * fixup_pct;
        }
        next_child = child.next;
    }
}

fn constrain_cross_axis(parent: *Box, comptime axis: Axis, avail: f32) void {
    const axis_index = @intFromEnum(axis);

    var next_child = parent.first;
    while (next_child) |child| {
        if (!is_floating(child, axis)) {
            child.fixed_size[axis_index] = @min(child.fixed_size[axis_index], avail);
        }
        next_child = child.next;
    }
}

// -----------------------------------------------------------------------
// Pass 5: Positioning
// -----------------------------------------------------------------------

fn pass_position(root: *Box, comptime axis: Axis) void {
    position_subtree(root, axis);
}

fn position_subtree(parent: *Box, comptime axis: Axis) void {
    const axis_index = @intFromEnum(axis);
    const insets = border_insets(parent);

    const parent_origin: f32 = if (axis == .x)
        @floatFromInt(parent.rect.col)
    else
        @floatFromInt(parent.rect.row);

    const avail = @max(parent.fixed_size[axis_index] - insets.before[axis_index] - insets.after[axis_index], 0);
    var cursor: f32 = parent_origin + insets.before[axis_index] - parent.view_off[axis_index];

    var next_child = parent.first;
    while (next_child) |child| {
        if (is_floating(child, axis)) {
            const pos = child.fixed_position[axis_index];
            set_rect_axis(child, axis, pos, child.fixed_size[axis_index]);
        } else {
            const size = snap(child.fixed_size[axis_index]);
            if (axis == parent.child_layout_axis) {
                set_rect_axis(child, axis, snap(cursor), size);
                cursor += child.fixed_size[axis_index];
            } else {
                const cross_pos = parent_origin + insets.before[axis_index];
                if (child.fixed_size[axis_index] <= 0) {
                    child.fixed_size[axis_index] = avail;
                }
                set_rect_axis(child, axis, snap(cross_pos), snap(child.fixed_size[axis_index]));
            }
        }

        child.fixed_size[axis_index] = @floatFromInt(rect_size(child, axis));

        position_subtree(child, axis);
        next_child = child.next;
    }
}

fn set_rect_axis(box: *Box, comptime axis: Axis, pos: f32, size: f32) void {
    const clamped_pos = clamp_u16(pos);
    const clamped_size = clamp_u16(size);
    if (axis == .x) {
        box.rect.col = clamped_pos;
        box.rect.w = clamped_size;
    } else {
        box.rect.row = clamped_pos;
        box.rect.h = clamped_size;
    }
}

fn rect_size(box: *const Box, comptime axis: Axis) u16 {
    return if (axis == .x) box.rect.w else box.rect.h;
}

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

fn border_insets(box: *const Box) struct { before: [2]f32, after: [2]f32 } {
    var before = [2]f32{ 0, 0 };
    var after = [2]f32{ 0, 0 };
    if (box.flags.draw_border) {
        if (box.flags.draw_side_left) before[0] = 1;
        if (box.flags.draw_side_right) after[0] = 1;
        if (box.flags.draw_side_top) before[1] = 1;
        if (box.flags.draw_side_bottom) after[1] = 1;
    }
    return .{ .before = before, .after = after };
}

fn is_floating(box: *const Box, comptime axis: Axis) bool {
    return if (axis == .x) box.flags.floating_x else box.flags.floating_y;
}

fn tree_next_within(current: *Box, root: *const Box) ?*Box {
    if (current.first) |first_child| return first_child;

    var node = current;
    while (true) {
        if (node == root) return null;
        if (node.next) |sibling| return sibling;
        node = node.parent orelse return null;
        if (node == root) return null;
    }
}

fn display_width(s: []const u8) usize {
    return draw.text_display_width(s);
}

fn snap(v: f32) f32 {
    return @trunc(v);
}

fn clamp_u16(v: f32) u16 {
    if (v <= 0) return 0;
    if (v >= 65535) return 65535;
    return @intFromFloat(v);
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const assert = std.debug.assert;
const testing = std.testing;
const base = @import("base");
const Arena = base.Arena;

fn make_box(arena: *Arena) !*Box {
    const b = try arena.create(Box);
    b.* = .{};
    return b;
}

fn link(parent: *Box, child: *Box) void {
    ui.push_child(parent, child);
}

test "three equal children in a row" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(30, 1), Size.cells(10, 1) };
    root.child_layout_axis = .x;

    var children: [3]*Box = undefined;
    for (&children) |*cp| {
        const c = try make_box(&arena);
        c.pref_size = .{ Size.cells(10, 1), Size.cells(10, 1) };
        link(root, c);
        cp.* = c;
    }

    layout(root, 30, 10);

    try testing.expectEqual(@as(u16, 0), children[0].rect.col);
    try testing.expectEqual(@as(u16, 10), children[0].rect.w);
    try testing.expectEqual(@as(u16, 10), children[1].rect.col);
    try testing.expectEqual(@as(u16, 10), children[1].rect.w);
    try testing.expectEqual(@as(u16, 20), children[2].rect.col);
    try testing.expectEqual(@as(u16, 10), children[2].rect.w);
}

test "parent_pct child" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(20, 1), Size.cells(10, 1) };
    root.child_layout_axis = .x;

    const child = try make_box(&arena);
    child.pref_size = .{ Size.pct(0.5, 1), Size.pct(1, 1) };
    link(root, child);

    layout(root, 20, 10);

    try testing.expectEqual(@as(u16, 10), child.rect.w);
    try testing.expectEqual(@as(u16, 10), child.rect.h);
}

test "children_sum parent" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(100, 1), Size.cells(100, 1) };
    root.child_layout_axis = .y;

    const container = try make_box(&arena);
    container.pref_size = .{ Size.children(1), Size.children(1) };
    container.child_layout_axis = .x;
    link(root, container);

    const c1 = try make_box(&arena);
    c1.pref_size = .{ Size.cells(5, 1), Size.cells(8, 1) };
    link(container, c1);

    const c2 = try make_box(&arena);
    c2.pref_size = .{ Size.cells(10, 1), Size.cells(6, 1) };
    link(container, c2);

    const c3 = try make_box(&arena);
    c3.pref_size = .{ Size.cells(8, 1), Size.cells(4, 1) };
    link(container, c3);

    layout(root, 100, 100);

    try testing.expectEqual(@as(u16, 23), container.rect.w);
    try testing.expectEqual(@as(u16, 8), container.rect.h);
}

test "overflow with strictness" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(30, 1), Size.cells(10, 1) };
    root.child_layout_axis = .x;

    const strict = try make_box(&arena);
    strict.pref_size = .{ Size.cells(20, 1), Size.cells(10, 1) };
    link(root, strict);

    const flex = try make_box(&arena);
    flex.pref_size = .{ Size.cells(20, 0), Size.cells(10, 1) };
    link(root, flex);

    layout(root, 30, 10);

    try testing.expectEqual(@as(u16, 20), strict.rect.w);
    try testing.expect(flex.rect.w <= 10);
}

test "nested row inside column" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(40, 1), Size.cells(20, 1) };
    root.child_layout_axis = .y;

    const row = try make_box(&arena);
    row.pref_size = .{ Size.pct(1, 1), Size.cells(5, 1) };
    row.child_layout_axis = .x;
    link(root, row);

    const left = try make_box(&arena);
    left.pref_size = .{ Size.cells(20, 1), Size.pct(1, 1) };
    link(row, left);

    const right = try make_box(&arena);
    right.pref_size = .{ Size.cells(20, 1), Size.pct(1, 1) };
    link(row, right);

    layout(root, 40, 20);

    try testing.expectEqual(@as(u16, 0), row.rect.col);
    try testing.expectEqual(@as(u16, 0), row.rect.row);
    try testing.expectEqual(@as(u16, 40), row.rect.w);
    try testing.expectEqual(@as(u16, 5), row.rect.h);

    try testing.expectEqual(@as(u16, 0), left.rect.col);
    try testing.expectEqual(@as(u16, 20), left.rect.w);
    try testing.expectEqual(@as(u16, 20), right.rect.col);
    try testing.expectEqual(@as(u16, 20), right.rect.w);
}

test "floating box uses fixed_position" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(80, 1), Size.cells(24, 1) };
    root.child_layout_axis = .y;

    const normal = try make_box(&arena);
    normal.pref_size = .{ Size.pct(1, 1), Size.cells(5, 1) };
    link(root, normal);

    const floating = try make_box(&arena);
    floating.pref_size = .{ Size.cells(10, 1), Size.cells(3, 1) };
    floating.flags.floating_x = true;
    floating.flags.floating_y = true;
    floating.fixed_position = .{ 30, 10 };
    link(root, floating);

    layout(root, 80, 24);

    try testing.expectEqual(@as(u16, 30), floating.rect.col);
    try testing.expectEqual(@as(u16, 10), floating.rect.row);
    try testing.expectEqual(@as(u16, 10), floating.rect.w);
    try testing.expectEqual(@as(u16, 3), floating.rect.h);
}

test "border insets reduce available space" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(20, 1), Size.cells(10, 1) };
    root.child_layout_axis = .x;
    root.flags.draw_border = true;
    root.flags.draw_side_left = true;
    root.flags.draw_side_right = true;
    root.flags.draw_side_top = true;
    root.flags.draw_side_bottom = true;

    const child = try make_box(&arena);
    child.pref_size = .{ Size.pct(1, 1), Size.pct(1, 1) };
    link(root, child);

    layout(root, 20, 10);

    try testing.expectEqual(@as(u16, 1), child.rect.col);
    try testing.expectEqual(@as(u16, 1), child.rect.row);
    try testing.expectEqual(@as(u16, 18), child.rect.w);
    try testing.expectEqual(@as(u16, 8), child.rect.h);
}

test "text_content sizing" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(80, 1), Size.cells(24, 1) };
    root.child_layout_axis = .y;

    const label = try make_box(&arena);
    label.display_string = "Hello";
    label.text_padding = 1;
    label.pref_size = .{ Size.text(0, 1), Size.text(0, 1) };
    link(root, label);

    layout(root, 80, 24);

    // "Hello" = 5 chars + 1 padding * 2 = 7
    try testing.expectEqual(@as(u16, 7), label.rect.w);
    try testing.expectEqual(@as(u16, 1), label.rect.h);
}

test "parent_pct child inside children_sum row fills sibling height" {
    var arena = try Arena.init(.{});
    defer arena.deinit();

    // Simulates the counter-row pattern from basic_ui:
    //   root (cells 80x24, axis .y)
    //     panel (pct(1) x children(1), axis .y)
    //       row (pct(1) x children(1), axis .x)
    //         label  (text x pct(1,0))   <-- should fill row height, NOT root height
    //         button (cells 7x3)

    const root = try make_box(&arena);
    root.pref_size = .{ Size.cells(80, 1), Size.cells(24, 1) };
    root.child_layout_axis = .y;

    const panel = try make_box(&arena);
    panel.pref_size = .{ Size.pct(1, 1), Size.children(1) };
    panel.child_layout_axis = .y;
    link(root, panel);

    const row = try make_box(&arena);
    row.pref_size = .{ Size.pct(1, 1), Size.children(1) };
    row.child_layout_axis = .x;
    link(panel, row);

    const label = try make_box(&arena);
    label.display_string = "Apples:";
    label.pref_size = .{ Size.text(0, 1), Size.pct(1, 0) };
    link(row, label);

    const button = try make_box(&arena);
    button.pref_size = .{ Size.cells(7, 1), Size.cells(3, 1) };
    link(row, button);

    layout(root, 80, 24);

    // Row height comes from the button (tallest fixed child = 3).
    try testing.expectEqual(@as(u16, 3), row.rect.h);
    // Panel wraps its single row child.
    try testing.expectEqual(@as(u16, 3), panel.rect.h);
    // Label should fill the row height (3), NOT the root height (24).
    try testing.expectEqual(@as(u16, 3), label.rect.h);
}
