//! Intrusive linked list implementations.
//!
//! `IntrusiveLinkedList` - singly-linked, element type must have `next: ?*T`
//! `IntrusiveDoublyLinkedList` - circular doubly-linked, element type must have `next: *T` and `prev: *T`
const std = @import("std");

pub fn IntrusiveLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        first: ?*T = null,

        pub const zero = Self{
            .first = null,
        };

        pub fn insert_after(node: *T, new_node: *T) void {
            new_node.next = node.next;
            node.next = new_node;
        }

        pub fn remove_next(node: *T) ?*T {
            const next_node = node.next orelse return null;
            node.next = next_node.next;
            return next_node;
        }

        pub fn find_last(node: *T) *T {
            var it = node;
            while (true) {
                it = it.next orelse return it;
            }
        }

        pub fn count(list: Self) usize {
            var c: usize = 0;
            var it: ?*const T = list.first;
            while (it) |n| : (it = n.next) {
                c += 1;
            }
            return c;
        }

        pub fn reverse(indirect: *?*T) void {
            if (indirect.* == null) {
                return;
            }
            var current: *T = indirect.*.?;
            while (current.next) |next| {
                current.next = next.next;
                next.next = indirect.*;
                indirect.* = next;
            }
        }

        pub fn prepend(list: *Self, new_node: *T) void {
            new_node.next = list.first;
            list.first = new_node;
        }

        pub fn remove(list: *Self, node: *T) void {
            if (list.first == node) {
                list.first = node.next;
            } else {
                var current_elm = list.first.?;
                while (current_elm.next != node) {
                    current_elm = current_elm.next.?;
                }
                current_elm.next = node.next;
            }
        }

        pub fn pop_first(list: *Self) ?*T {
            const first = list.first orelse return null;
            list.first = first.next;
            return first;
        }

        pub fn concat(list: *Self, other: Self) void {
            if (other.first == null) return;
            if (list.first == null) {
                list.first = other.first;
                return;
            }
            find_last(list.first.?).next = other.first;
        }
    };
}

/// Circular doubly-linked list. `prev` of `first` always points to the last element.
/// `next` of the last element points back to `first`.
/// Element type must have `next: *T` and `prev: *T` fields.
pub fn IntrusiveDoublyLinkedList(comptime T: type) type {
    if (!@hasField(T, "prev")) {
        @compileError("T type must have field `prev: *" ++ @typeName(T) ++ "`");
    }
    if (!@hasField(T, "next")) {
        @compileError("T type must have field `next: *" ++ @typeName(T) ++ "`");
    }

    return struct {
        const Self = @This();

        first: ?*T = null,

        pub const zero = Self{
            .first = null,
        };

        pub fn prepend(list: *Self, new_node: *T) void {
            if (list.first) |first| {
                new_node.next = first;
                new_node.prev = first.prev;
                first.prev.next = new_node;
                first.prev = new_node;
            } else {
                new_node.next = new_node;
                new_node.prev = new_node;
            }
            list.first = new_node;
        }

        pub fn append(list: *Self, new_node: *T) void {
            if (list.first) |first| {
                new_node.next = first;
                new_node.prev = first.prev;
                first.prev.next = new_node;
                first.prev = new_node;
            } else {
                new_node.next = new_node;
                new_node.prev = new_node;
                list.first = new_node;
            }
        }

        pub fn insert_after(node: *T, new_node: *T) void {
            new_node.next = node.next;
            new_node.prev = node;
            node.next.prev = new_node;
            node.next = new_node;
        }

        pub fn insert_before(node: *T, new_node: *T) void {
            new_node.prev = node.prev;
            new_node.next = node;
            node.prev.next = new_node;
            node.prev = new_node;
        }

        pub fn remove(list: *Self, node: *T) void {
            if (node.next == node) {
                list.first = null;
            } else {
                node.prev.next = node.next;
                node.next.prev = node.prev;
                if (list.first == node) {
                    list.first = node.next;
                }
            }
        }

        pub fn pop_first(list: *Self) ?*T {
            const first = list.first orelse return null;
            list.remove(first);
            return first;
        }

        pub fn pop_last(list: *Self) ?*T {
            const first = list.first orelse return null;
            const last_node = first.prev;
            list.remove(last_node);
            return last_node;
        }

        pub fn last(list: Self) ?*T {
            const first = list.first orelse return null;
            return first.prev;
        }

        pub fn concat(list: *Self, other: Self) void {
            const other_first = other.first orelse return;
            const first = list.first orelse {
                list.first = other_first;
                return;
            };
            const last_node = first.prev;
            const other_last = other_first.prev;

            last_node.next = other_first;
            other_first.prev = last_node;
            other_last.next = first;
            first.prev = other_last;
        }

        pub fn count(list: Self) usize {
            const first = list.first orelse return 0;
            var c: usize = 1;
            var it = first.next;
            while (it != first) : (it = it.next) {
                c += 1;
            }
            return c;
        }

        pub const Iter = struct {
            list: *const Self,
            node: ?*T,

            pub fn next(self: *Iter) ?*T {
                const node = self.node;
                if (node) |n| {
                    self.node =
                        if (n.next != self.list.first)
                            n.next
                        else
                            null;
                }
                return node;
            }
        };

        pub fn iter(list: *const Self) Iter {
            return Iter{
                .list = list,
                .node = list.first,
            };
        }
    };
}
