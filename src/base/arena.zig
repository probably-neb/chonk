const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const RESERVE_SIZE_DEFAULT: usize = 64 * 1024 * 1024 * 1024; // 64 GB of virtual address space
pub const COMMIT_GRANULARITY_DEFAULT: usize = 64 * 1024; // 64 KB
pub const page_size = std.heap.page_size_min;

const Arena = @This();

memory: [*]align(page_size) u8,
capacity: usize,
pos: usize,
committed: usize,
commit_size: usize,

pub const zero = Arena{
    .capacity = 0,
    .commit_size = 0,
    .committed = 0,
    .memory = &.{},
    .pos = 0,
};

pub const InitOptions = struct {
    reserve_size: usize = RESERVE_SIZE_DEFAULT,
    commit_size: usize = COMMIT_GRANULARITY_DEFAULT,
};

pub const InitError = error{
    OutOfMemory,
    AccessDenied,
    PermissionDenied,
    LockedMemoryLimitExceeded,
    MemoryMappingNotSupported,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    MappingAlreadyExists,
    Unexpected,
};

pub const AllocError = error{OutOfMemory};

pub fn init(options: InitOptions) InitError!Arena {
    const reserve_size = std.mem.alignForward(usize, options.reserve_size, page_size);
    const memory = try virtualalloc(reserve_size);

    return .{
        .memory = memory.ptr,
        .capacity = reserve_size,
        .pos = 0,
        .committed = 0,
        .commit_size = options.commit_size,
    };
}

pub fn release(self: *Arena) void {
    self.deinit();
}

pub fn deinit(self: *Arena) void {
    if (self.capacity > 0) {
        virtualfree(self.memory[0..self.capacity]);
    }
    self.* = .zero;
}

pub fn push(arena: *Arena, size: usize) AllocError![]u8 {
    return arena.push_aligned(size, 1);
}

pub fn push_aligned(arena: *Arena, size: usize, alignment: usize) AllocError![]u8 {
    const aligned_pos = std.mem.alignForward(usize, arena.pos, alignment);
    const new_pos = aligned_pos + size;

    if (new_pos > arena.capacity) {
        return error.OutOfMemory;
    }

    if (new_pos > arena.committed) {
        try arena.commit_up_to(new_pos);
    }

    arena.pos = new_pos;
    return arena.memory[aligned_pos..new_pos];
}

pub fn expand(arena: *Arena, comptime T: type, slice: []T, new_len: usize) AllocError![]T {
    if (new_len <= slice.len) return slice[0..new_len];
    if (@intFromPtr(slice.ptr) % @alignOf(T) != 0) return error.OutOfMemory;

    const old_byte_len, const old_overflow = @mulWithOverflow(@sizeOf(T), slice.len);
    if (old_overflow != 0) return error.OutOfMemory;

    const new_byte_len, const new_overflow = @mulWithOverflow(@sizeOf(T), new_len);
    if (new_overflow != 0) return error.OutOfMemory;

    const slice_start = @intFromPtr(slice.ptr);
    const arena_start = @intFromPtr(arena.memory);
    const arena_end = arena_start + arena.pos;

    if (slice_start + old_byte_len != arena_end) return error.OutOfMemory;

    const new_pos = arena.pos + (new_byte_len - old_byte_len);
    if (new_pos > arena.capacity) return error.OutOfMemory;

    if (new_pos > arena.committed) {
        try arena.commit_up_to(new_pos);
    }

    arena.pos = new_pos;
    return slice.ptr[0..new_len];
}

pub fn push_zero(arena: *Arena, size: usize) AllocError![]u8 {
    return arena.push_zero_aligned(size, 1);
}

pub fn push_zero_aligned(arena: *Arena, size: usize, alignment: usize) AllocError![]u8 {
    const slice = try arena.push_aligned(size, alignment);
    @memset(slice, 0);
    return slice;
}

pub fn dupe(arena: *Arena, comptime T: type, src: []const u8) AllocError![]T {
    const dst = try arena.alloc(T, src.len);
    @memcpy(dst, src);
    return dst;
}

pub fn create(arena: *Arena, comptime T: type) AllocError!*T {
    const slice = try arena.push_zero_aligned(@sizeOf(T), @alignOf(T));
    return @ptrCast(@alignCast(slice.ptr));
}

pub fn alloc(arena: *Arena, comptime T: type, n: usize) AllocError![]T {
    const byte_size = @sizeOf(T) * n;
    const slice = try arena.push_aligned(byte_size, @alignOf(T));
    return @as([*]T, @ptrCast(@alignCast(slice.ptr)))[0..n];
}

pub fn alloc_zero(arena: *Arena, comptime T: type, n: usize) AllocError![]T {
    const byte_size = @sizeOf(T) * n;
    const slice = try arena.push_zero_aligned(byte_size, @alignOf(T));
    return @as([*]T, @ptrCast(@alignCast(slice.ptr)))[0..n];
}

pub fn pop(arena: *Arena, size: usize) void {
    arena.pos = if (size > arena.pos) 0 else arena.pos - size;
}

pub fn get_pos(arena: *const Arena) usize {
    return arena.pos;
}

pub fn set_pos(arena: *Arena, new_pos: usize) void {
    if (new_pos < arena.pos) {
        arena.pos = new_pos;
    }
}

pub fn clear(arena: *Arena) void {
    arena.pos = 0;
}

pub fn scoped(arena: *Arena) Scoped {
    return .{ .arena = arena, .pos = arena.pos };
}

pub fn allocator(arena: *Arena) std.mem.Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{
            .alloc = alloc_fn,
            .resize = resize_fn,
            .remap = remap_fn,
            .free = free_fn,
        },
    };
}

fn alloc_fn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
    const arena: *Arena = @ptrCast(@alignCast(ctx));
    const alignment = ptr_align.toByteUnits();
    const slice = arena.push_aligned(len, alignment) catch return null;
    return slice.ptr;
}

fn resize_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}

fn remap_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}

fn free_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}

fn commit_up_to(arena: *Arena, target_pos: usize) AllocError!void {
    const new_committed = std.mem.alignForward(usize, target_pos, arena.commit_size);
    const commit_target = @min(new_committed, arena.capacity);

    if (commit_target <= arena.committed) {
        return;
    }

    const start = arena.committed;
    const len = commit_target - start;

    virtualcommit(arena.memory, start, len) catch return error.OutOfMemory;

    arena.committed = commit_target;
}

pub const Scoped = struct {
    arena: *Arena,
    pos: usize,

    pub fn release(s: Scoped) void {
        s.arena.set_pos(s.pos);
    }
};

fn virtualalloc(reserve_size: usize) InitError![]align(page_size) u8 {
    const size = std.mem.alignForward(usize, reserve_size, page_size);

    switch (builtin.os.tag) {
        .windows => {
            const w = std.os.windows;

            const ptr = w.kernel32.VirtualAlloc(
                null,
                size,
                w.MEM.RESERVE,
                w.PAGE.NOACCESS,
            );

            if (ptr == null) return error.OutOfMemory;

            return @as([*]align(page_size) u8, @ptrCast(@alignCast(ptr)))[0..size];
        },
        else => {
            return try posix.mmap(
                null,
                size,
                posix.PROT.NONE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );
        },
    }
}

fn virtualcommit(base: [*]align(page_size) u8, start: usize, len: usize) InitError!void {
    if (len == 0) return;

    switch (builtin.os.tag) {
        .windows => {
            const w = std.os.windows;
            const addr: ?*anyopaque = @ptrCast(base + start);
            const p = w.kernel32.VirtualAlloc(
                addr,
                len,
                w.MEM.COMMIT,
                w.PAGE.READWRITE,
            );
            if (p == null) return error.OutOfMemory;
        },
        else => {
            const slice: []align(page_size) u8 = @alignCast(base[start .. start + len]);
            try posix.mprotect(slice, posix.PROT.READ | posix.PROT.WRITE);
        },
    }
}

fn virtualfree(base: []align(page_size) u8) void {
    switch (builtin.os.tag) {
        .windows => {
            const w = std.os.windows;
            const ptr: ?*anyopaque = @ptrCast(base.ptr);
            _ = w.kernel32.VirtualFree(ptr, 0, w.MEM.RELEASE);
        },
        else => {
            posix.munmap(base);
        },
    }
}

/// Wraps an Arena with a free list for memory reuse without resetting the entire arena.
pub const FreeList = struct {
    arena: *Arena,
    free_head: ?*FreeNode,

    const FreeNode = struct {
        next: ?*FreeNode,
        size: usize,
    };

    pub const min_alloc_size = @max(2 * @sizeOf(usize), @alignOf(FreeNode));
    pub const min_alignment = @alignOf(FreeNode);

    pub fn init(arena: *Arena) FreeList {
        return .{ .arena = arena, .free_head = null };
    }

    pub fn allocator(free_list: *FreeList) std.mem.Allocator {
        return .{
            .ptr = free_list,
            .vtable = &.{
                .alloc = freelist_alloc_fn,
                .resize = freelist_resize_fn,
                .remap = freelist_remap_fn,
                .free = freelist_free_fn,
            },
        };
    }

    fn freelist_alloc_fn(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
        const free_list: *FreeList = @ptrCast(@alignCast(ctx));
        return free_list.alloc_internal(len, ptr_align);
    }

    fn alloc_internal(free_list: *FreeList, len: usize, ptr_align: std.mem.Alignment) ?[*]u8 {
        const alignment = @max(ptr_align.toByteUnits(), min_alignment);
        const alloc_size = @max(len, min_alloc_size);

        var prev: ?*FreeNode = null;
        var current = free_list.free_head;

        while (current) |node| {
            const node_addr = @intFromPtr(node);
            const aligned_addr = std.mem.alignForward(usize, node_addr, alignment);
            const padding = aligned_addr - node_addr;

            if (node.size >= alloc_size + padding) {
                if (prev) |p| {
                    p.next = node.next;
                } else {
                    free_list.free_head = node.next;
                }
                return @ptrFromInt(aligned_addr);
            }

            prev = node;
            current = node.next;
        }

        const slice = free_list.arena.push_aligned(alloc_size, alignment) catch return null;
        return slice.ptr;
    }

    fn freelist_resize_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn freelist_remap_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn freelist_free_fn(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const free_list: *FreeList = @ptrCast(@alignCast(ctx));
        free_list.free_internal(buf);
    }

    fn free_internal(free_list: *FreeList, buf: []u8) void {
        if (buf.len == 0) return;

        const size = @max(buf.len, min_alloc_size);
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.* = .{ .next = free_list.free_head, .size = size };
        free_list.free_head = node;
    }

    pub fn clear(free_list: *FreeList) void {
        free_list.free_head = null;
    }
};

const scratch_arena_count = 2;
threadlocal var scratch_arenas: [scratch_arena_count]?Arena = .{null} ** scratch_arena_count;

/// Get a thread-local scratch arena. Pass conflicting arenas to avoid getting the same one.
pub fn get_scratch(conflicts: []const *const Arena) Scoped {
    for (&scratch_arenas) |*maybe_arena| {
        if (maybe_arena.* == null) {
            maybe_arena.* = Arena.init(.{}) catch @panic("Failed to initialize scratch arena");
        }
    }

    for (&scratch_arenas) |*maybe_arena| {
        const arena = &(maybe_arena.*.?);
        var is_conflict = false;
        for (conflicts) |conflict| {
            if (@intFromPtr(arena) == @intFromPtr(conflict)) {
                is_conflict = true;
                break;
            }
        }
        if (!is_conflict) {
            return arena.scoped();
        }
    }

    @panic("All scratch arenas are in conflict");
}

pub fn deinit_scratch_arenas() void {
    for (&scratch_arenas) |*maybe_arena| {
        if (maybe_arena.*) |*arena| {
            arena.deinit();
            maybe_arena.* = null;
        }
    }
}

test "Arena: basic allocation" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    const slice1 = try arena.push(100);
    try std.testing.expectEqual(@as(usize, 100), slice1.len);

    const slice2 = try arena.push(200);
    try std.testing.expectEqual(@as(usize, 200), slice2.len);
    try std.testing.expectEqual(slice1.ptr + 100, slice2.ptr);
}

test "Arena: typed allocation" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    const Point = struct { x: i32, y: i32 };

    const point = try arena.create(Point);
    point.x = 10;
    point.y = 20;

    try std.testing.expectEqual(@as(i32, 10), point.x);
    try std.testing.expectEqual(@as(i32, 20), point.y);

    const points = try arena.alloc(Point, 10);
    try std.testing.expectEqual(@as(usize, 10), points.len);
}

test "Arena: zeroed allocation" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    const slice = try arena.push_zero(100);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Arena: clear and reuse" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    _ = try arena.push(1000);
    try std.testing.expectEqual(@as(usize, 1000), arena.get_pos());

    arena.clear();
    try std.testing.expectEqual(@as(usize, 0), arena.get_pos());
    _ = try arena.push(500);
    try std.testing.expectEqual(@as(usize, 500), arena.get_pos());
}

test "Arena: scope" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    _ = try arena.push(100);
    const pos_before = arena.get_pos();

    {
        const s = arena.scoped();
        defer s.release();

        _ = try arena.push(500);
        try std.testing.expectEqual(pos_before + 500, arena.get_pos());
    }
    try std.testing.expectEqual(pos_before, arena.get_pos());
}

test "Arena: std.mem.Allocator interface" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    const ally = arena.allocator();

    const slice = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice.len);
    ally.free(slice);
}

test "scratch arenas: basic usage" {
    defer deinit_scratch_arenas();

    const scratch = get_scratch(&.{});
    defer scratch.release();

    _ = try scratch.arena.push(100);
}

test "scratch arenas: conflict avoidance" {
    defer deinit_scratch_arenas();

    var arena1 = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena1.deinit();

    const scratch1 = get_scratch(&.{});
    const scratch2 = get_scratch(&.{scratch1.arena});
    try std.testing.expect(scratch1.arena != scratch2.arena);

    scratch2.release();
    scratch1.release();
}

test "Arena: expand respects last allocation and sizes" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    const first = try arena.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), first.len);

    const last = try arena.alloc(u16, 4);
    try std.testing.expectEqual(@as(usize, 4), last.len);

    const expanded = try arena.expand(u16, last, 10);
    try std.testing.expectEqual(@as(usize, 10), expanded.len);
    try std.testing.expectEqual(@as(usize, 8 + 10 * @sizeOf(u16)), arena.get_pos());

    _ = try arena.alloc(u8, 1);

    try std.testing.expectError(error.OutOfMemory, arena.expand(u16, expanded, 12));
}

test "FreeList: basic allocation and reuse" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    var free_list = FreeList.init(&arena);
    const ally = free_list.allocator();

    const slice1 = try ally.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice1.len);

    const pos_after_alloc = arena.get_pos();
    ally.free(slice1);

    const slice2 = try ally.alloc(u8, 50);
    try std.testing.expectEqual(@as(usize, 50), slice2.len);
    try std.testing.expectEqual(pos_after_alloc, arena.get_pos());
}

test "FreeList: minimum allocation size" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    var free_list = FreeList.init(&arena);
    const ally = free_list.allocator();

    const slice = try ally.alloc(u8, 1);
    try std.testing.expectEqual(@as(usize, 1), slice.len);
    ally.free(slice);

    const slice2 = try ally.alloc(u8, FreeList.min_alloc_size);
    try std.testing.expectEqual(@as(usize, FreeList.min_alloc_size), slice2.len);
}

test "FreeList: multiple allocations and frees" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    var free_list = FreeList.init(&arena);
    const ally = free_list.allocator();

    const a = try ally.alloc(u8, FreeList.min_alloc_size);
    const b = try ally.alloc(u8, FreeList.min_alloc_size * 2);
    const c = try ally.alloc(u8, FreeList.min_alloc_size * 3);

    const pos_after_allocs = arena.get_pos();

    ally.free(c);
    ally.free(b);
    ally.free(a);

    _ = try ally.alloc(u8, FreeList.min_alloc_size);
    _ = try ally.alloc(u8, FreeList.min_alloc_size * 2);
    _ = try ally.alloc(u8, FreeList.min_alloc_size * 3);
    try std.testing.expectEqual(pos_after_allocs, arena.get_pos());
}

test "FreeList: typed allocations" {
    var arena = try Arena.init(.{ .reserve_size = 1024 * 1024 });
    defer arena.deinit();

    var free_list = FreeList.init(&arena);
    const ally = free_list.allocator();

    const Point = struct { x: i32, y: i32, z: i32 };

    const points = try ally.alloc(Point, 10);
    try std.testing.expectEqual(@as(usize, 10), points.len);

    points[0] = .{ .x = 1, .y = 2, .z = 3 };
    try std.testing.expectEqual(@as(i32, 1), points[0].x);

    ally.free(points);
}
