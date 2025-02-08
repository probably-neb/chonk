//! Base Layer
//!
//! Provides foundational utilities and abstractions for JSONLS.
//!
const std = @import("std");

pub const Arena = @import("arena.zig");
pub const ArenaList = @import("arena-list.zig").ArenaList;
pub const ArenaListAligned = @import("arena-list.zig").ArenaListAligned;
pub const IntrusiveLinkedList = @import("intrusive-linked-list.zig").IntrusiveLinkedList;
pub const IntrusiveDoublyLinkedList = @import("intrusive-linked-list.zig").IntrusiveDoublyLinkedList;
pub const meta = @import("meta.zig");

test {
    std.testing.refAllDecls(@This());
}

pub fn Range(comptime T: type) type {
    return struct {
        start: T,
        close: T,

        pub const zero = std.mem.zeroes(@This());

        pub fn len(self: @This()) T {
            if (std.meta.hasMethod(T, "sub")) {
                return self.close.sub(self.start);
            }
            return self.close - self.start;
        }

        pub fn range(start: anytype, close: @TypeOf(start)) Range(@TypeOf(start)) {
            return .{ .start = start, .close = close };
        }

        pub fn range_of(comptime R: type, start: R, close: R) Range(R) {
            return .{ .start = start, .close = close };
        }
    };
}
