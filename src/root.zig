const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

pub const TopLevelPath = struct {
    path: [:0]const u8,
    device: ?[:0]const u8 = null,
};

pub fn get_top_level_paths(alloc: Allocator, scratch: Allocator) ![]TopLevelPath {
    var file_list = std.array_list.Managed(TopLevelPath).init(alloc);

    home: {
        const home_path = std.process.getEnvVarOwned(scratch, "HOME") catch |err| {
            std.debug.print("ERROR: failed to read home dir env var: {any}\n", .{err});
            break :home;
        };
        if (home_path.len == 0) {
            break :home;
        }
        const home_path_zt = try alloc.dupeZ(u8, home_path);

        try file_list.append(.{ .path = home_path_zt });
    }

    mounts: {
        const mounts_file = std.fs.openFileAbsolute("/proc/mounts", .{
            .mode = .read_only,
        }) catch |err| {
            std.debug.print("ERROR: failed to retrieve mount points: {any}\n", .{err});
            break :mounts;
        };
        const contents = mounts_file.readToEndAlloc(scratch, std.math.maxInt(usize)) catch |err| {
            std.debug.print("ERROR: failed to read mount points file: {any}\n", .{err});
            break :mounts;
        };
        var line_iter = std.mem.tokenizeScalar(u8, contents, '\n');
        while (line_iter.next()) |line| {
            var tok_iter = std.mem.tokenizeScalar(u8, line, ' ');
            const device = tok_iter.next() orelse continue;
            const path = tok_iter.next() orelse continue;
            if (!std.mem.startsWith(u8, device, "/dev")) {
                continue;
            }
            if (std.mem.startsWith(u8, path, "/boot")) {
                continue;
            }
            try file_list.append(.{
                .path = try alloc.dupeZ(u8, path),
                .device = try alloc.dupeZ(u8, device),
            });
        }
    }
    return file_list.items;
}

pub const FileSizeEntry = struct {
    size: u64,
    abs_path: std.BoundedArray(u8, std.fs.max_path_bytes),

    pub const BATCH_SIZE_MAX = 64;
};

const fts = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fts.h");
});

const FTS_Info = enum(c_int) {
    /// A directory being visited in preorder.
    D = fts.FTS_D,

    /// A directory that causes a cycle in the tree.  (The
    /// fts_cycle field of the FTSENT structure will be
    /// filled in as well.)
    DC = fts.FTS_DC,

    /// Any FTSENT structure that represents a file type
    /// not explicitly described by one of the other
    /// fts_info values.
    DEFAULT = fts.FTS_DEFAULT,

    /// A directory which cannot be read.  This is an error
    /// return, and the fts_errno field will be set to
    /// indicate what caused the error.
    DNR = fts.FTS_DNR,

    /// A file named "."  or ".."  which was not specified
    /// as a filename to fts_open() (see FTS_SEEDOT).
    DOT = fts.FTS_DOT,

    /// A directory being visited in postorder.  The
    /// contents of the FTSENT structure will be unchanged
    /// from when it was returned in preorder, that is,
    /// with the fts_info field set to FTS_D.
    DP = fts.FTS_DP,

    /// This is an error return, and the fts_errno field
    /// will be set to indicate what caused the error.
    ERR = fts.FTS_ERR,

    /// A regular file.
    F = fts.FTS_F,

    /// A file for which no [l]stat(2) information was
    /// available.  The contents of the fts_statp field are
    /// undefined.  This is an error return, and the
    /// fts_errno field will be set to indicate what caused
    /// the error.
    NS = fts.FTS_NS,

    /// A file for which no [l]stat(2) information was
    /// requested.  The contents of the fts_statp field are
    /// undefined.
    NSOK = fts.FTS_NSOK,

    /// A symbolic link.
    SL = fts.FTS_SL,

    /// A symbolic link with a nonexistent target.  The
    /// contents of the fts_statp field reference the file
    /// characteristic information for the symbolic link
    /// itself.
    SLNONE = fts.FTS_SLNONE,
};

const DBG_PRINT_ENABLE = false;
const dbg_print = if (DBG_PRINT_ENABLE) std.debug.print else struct {
    fn print(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
}.print;

pub fn index_paths_starting_with(root_path: [:0]const u8, base_alloc: Allocator, store: *FS_Store, files_indexed: *u64) void {
    const fs = std.fs;
    var timer = std.time.Timer.start() catch null;
    // defer base_alloc.free(root_path);

    // var arena = std.heap.ArenaAllocator.init(base_alloc);
    // const alloc = arena.allocator();
    // defer arena.deinit();

    if (!fs.path.isAbsolute(root_path)) {
        std.debug.print("WARN: NOT ABSOLUTE: '{s}'\n", .{root_path});
        return;
    }

    const path_args: [2][*c]u8 = .{ @ptrCast(@constCast(root_path)), @ptrFromInt(0) };

    const state: *fts.FTS = fts.fts_open(&path_args, fts.FTS_PHYSICAL, null);
    defer _ = fts.fts_close(state);

    dbg_print("INDEX START : {s}\n", .{root_path});

    var cursor: FS_Store.Cursor = store.new_cursor_at(root_path) catch |err| {
        std.debug.print("Failed to init cursor at {s} :: {}\n", .{ root_path, err });
        return;
    };

    var fts_entry: ?*fts.FTSENT = fts.fts_read(state);

    var prev_path: []const u8 = base_alloc.dupe(u8, root_path) catch unreachable;
    defer base_alloc.free(prev_path);

    while (fts_entry) |fts_ent| : (fts_entry = fts.fts_read(state)) {
        if (fts_ent.fts_level == 0 and cursor.depth == 1) {
            std.debug.print("INDEXING COMPLETED: {}ms FINAL SIZE={} bytes\n", .{
                (if (timer) |*t| t.read() else 0) / std.time.ns_per_ms,
                cursor.store.extent * FS_Store.PAGE_SIZE,
            });
            return;
        }
        _ = @atomicRmw(u64, files_indexed, .Add, 1, .monotonic);
        const path = @as([*]u8, @ptrCast(fts_ent.fts_path))[0..fts_ent.fts_pathlen];
        defer if (fts_ent.fts_info == fts.FTS_D) {
            base_alloc.free(prev_path);
            prev_path = base_alloc.dupe(u8, path) catch unreachable;
        };
        // files_indexed.* += 1;
        const name = @as([*]u8, @ptrCast(&fts_ent.fts_name))[0..fts_ent.fts_namelen];

        if (fts_ent.fts_info == fts.FTS_D or fts_ent.fts_info == fts.FTS_F or fts_ent.fts_info == fts.FTS_SL) {
            dbg_print("VISITING '{s}' [cursor_name={s}] [depth={d}]\n", .{ path, cursor.cur.name[0..cursor.cur.name_len], cursor.depth });
        }

        switch (fts_ent.fts_info) {
            fts.FTS_D => {},
            fts.FTS_F, fts.FTS_SL => continue, // handled by children call
            fts.FTS_DP => {
                // TODO: use variables left in FTENT structure for user use to keep track of child index and
                // create backtrack_index fn to avoid search
                dbg_print("BACKTRACKING FROM '{s}' -> '{s}' [name={s}] [cursor_name={s}]\n", .{ prev_path, path, name, cursor.cur.name[0..cursor.cur.name_len] });
                if (fts_ent.fts_level == cursor.depth and mem.eql(u8, cursor.cur.name[0..cursor.cur.name_len], name)) {
                    continue;
                }
                cursor.backtrack(name);
                continue;
            },
            else => {
                // TODO: handle errors
                continue;
            },
        }
        if (fts_ent.fts_level > 0) {
            if (fts_ent.fts_level == cursor.depth) {
                // stepping sideways, backtrack to parent before recursing into sibling
                cursor.backtrack(cursor.parent.name[0..cursor.parent.name_len]);
            }
            cursor.recurse_into(name) catch {
                unreachable;
            };
        }

        const children: ?*fts.FTSENT = fts.fts_children(state, 0);

        var child = children;
        var count: u32 = 0;
        while (child) |c| : (count += 1) {
            child = c.fts_link;
        }

        cursor.children_begin(count);
        defer cursor.children_end();

        child = children;

        while (child) |c| {
            defer child = c.fts_link;
            // TODO: simd kind getting
            var kind: FS_Store.Entry.FileKind = .unknown;

            // FIXME: use FTS_Info enum & @enumFromInt for exhaustive switch here and no error
            switch (c.fts_info) {
                fts.FTS_D => kind = .dir,
                fts.FTS_F => kind = .file,
                fts.FTS_SL => kind = .link_soft, // TODO: ensure proper handling of hard/soft link sizes
                fts.FTS_DP => {
                    unreachable;
                },
                fts.FTS_DEFAULT => {},
                fts.FTS_ERR => {
                    const val: FTS_Info = @enumFromInt(c.fts_info);
                    const child_path = @as([*]u8, @ptrCast(&c.fts_path))[0..c.fts_pathlen];
                    const errno: std.posix.E = @enumFromInt(@abs(c.fts_errno));
                    std.debug.print("WARN: cannot visit '{s}' :: FTS_{s} :: [errno={s}] \n", .{ child_path, @tagName(val), @tagName(errno) });
                },
                fts.FTS_DNR => {
                    const val: FTS_Info = @enumFromInt(c.fts_info);
                    const child_path = @as([*]u8, @ptrCast(&c.fts_path))[0..c.fts_pathlen];
                    const errno: std.posix.E = @enumFromInt(@abs(fts_ent.fts_errno));
                    std.debug.print("WARN: cannot read dir '{s}' :: FTS_{s} :: [errno={s}] \n", .{ child_path, @tagName(val), @tagName(errno) });
                },
                fts.FTS_NS => {
                    const val: FTS_Info = @enumFromInt(c.fts_info);
                    const child_path = @as([*]u8, @ptrCast(&c.fts_path))[0..c.fts_pathlen];
                    const errno: std.posix.E = @enumFromInt(@abs(fts_ent.fts_errno));
                    std.debug.print("WARN: cannot stat file '{s}' :: FTS_{s} :: [errno={s}] \n", .{ child_path, @tagName(val), @tagName(errno) });
                },
                else => |info_val| {
                    const val: FTS_Info = @enumFromInt(info_val);
                    const child_path = @as([*]u8, @ptrCast(&c.fts_name))[0..c.fts_namelen];
                    const errno: std.posix.E = @enumFromInt(@abs(fts_ent.fts_errno));
                    std.debug.print("ERROR: cannot visit '{s}' :: {s} :: [errno={s}] \n", .{ child_path, @tagName(val), @tagName(errno) });
                    unreachable;
                },
            }

            // TODO: inode
            const entry_ptr = cursor.child_init();
            defer cursor.child_finish();

            const child_byte_count: u64, const child_block_count: u64 = if (@as(?*fts.struct_stat, c.fts_statp)) |stat_info|
                .{ @intCast(stat_info.st_size), @intCast(stat_info.st_blocks) } // TODO: check st_blocksize
            else
                .{ 0, 0 };

            const child_name = @as([*]u8, @ptrCast(&c.fts_name))[0..c.fts_namelen];
            dbg_print("CHILD NAME = {s}\n", .{child_name});

            entry_ptr.byte_count = child_byte_count;
            entry_ptr.block_count = child_block_count;
            entry_ptr.kind = @intFromEnum(kind);
            @memcpy(entry_ptr.name[0..child_name.len], child_name);
            entry_ptr.name[child_name.len] = 0;
            entry_ptr.name_len = @intCast(child_name.len);
        }
    }

    return;
}

// REQUIREMENTS
// - allow multiple concurrent writes to different subtrees
// - some sort of cursor mechanism for saving current location in tree
// - packing nodes as tightly together as possible
// - packing adjacent entries together
//
// DATA
// - path name part
// -- variable (< `getconf NAME_MAX /` ~~ 255)
// -- store index into large byte buffer
// --- requires deduplication to be size efficient
// --- could duplicate tree chunk (idx + count) logic to name sizes to load fixed number of pages
// -- or just store inode and when name is needed walk dir to correlate inode to name
// - kind (u4 / u8)
// - children ptrs
// -- if adjacent children are packed together, then only need
// --- u64: page index of start
// --- u16? count
// - apparent size: u64 = count bytes
// -     disk size: u64 = number of blocks
// - mtime/read time: u64
pub const FS_Store = struct {
    ptr: [*]align(PAGE_SIZE) u8,
    root_entry_ptr: *Entry,
    root_path: [:0]u8,
    entries: []Entry,
    extent: u32,
    extent_max: u32,

    const posix = std.posix;
    const PAGE_SIZE = std.heap.page_size_min;
    const MMAP_SIZE = PAGE_SIZE * 4_000_000; //6_000_000; // ~ 122GB of Virtual Address Space

    pub const ROOT_ENTRY_INDEX = std.math.maxInt(u32);

    // 1 page for metadata + root entry
    // 1 page for root entry path
    const HEADER_PAGES_COUNT = 2;

    const ENTRIES_PER_PAGE = @divExact(PAGE_SIZE, Entry.SIZE);

    pub fn init(self: *FS_Store, path: [:0]const u8) !void {
        const fd = if (@import("builtin").mode == .Debug)
            -1 // in memory only
        else {
            unreachable;
            // var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            // var path_alloc = std.heap.FixedBufferAllocator.init(path_buf);
            // const path = FS_Store.resolve_path(path_alloc.allocator()) catch unreachable;
            // var file = std.fs.openFileAbsolute()

        };
        _ = std.heap.page_allocator;
        const pages = posix.mmap(
            null,
            MMAP_SIZE,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, // FIXME: non-private + figure out what anonymous means when actually using fs
            fd,
            0,
        ) catch |err| {
            std.debug.print("ERROR: FAILED TO MMAP FS STORE: {}\n", .{err});
            return err;
        };
        self.ptr = pages.ptr;
        self.extent_max = @intCast(@divExact(pages.len, PAGE_SIZE));

        // FIXME: use self.ptr[0..PAGE_SIZE - Entry.SIZE] for metadata
        self.root_entry_ptr = @ptrCast(self.ptr + PAGE_SIZE - Entry.SIZE);
        self.root_entry_ptr.* = mem.zeroes(Entry);
        self.root_entry_ptr.lock_this = 1;

        // TODO: save root_entry_name len somehow in root entry (cast name as u16 and store there?)

        std.debug.assert(path.len < PAGE_SIZE - 1);
        self.root_path.ptr = @ptrCast(self.ptr + PAGE_SIZE);
        self.root_path.len = path.len;
        @memcpy(self.root_path, path);
        self.root_path[path.len] = 0;

        self.extent = HEADER_PAGES_COUNT;

        const entries_ptr: [*]Entry = @ptrCast(self.ptr + (PAGE_SIZE * HEADER_PAGES_COUNT));
        const entries_count_max = (self.extent_max - HEADER_PAGES_COUNT) * ENTRIES_PER_PAGE;
        self.entries = entries_ptr[0..entries_count_max];
    }

    pub fn new_cursor_at(self: *FS_Store, path: []const u8) !Cursor {
        // TODO: look at root node at end of metadata page
        //       if root not empty => assert is subpath & recurse & find then initialize with partent etc
        //                    else => initialize root to be base path and expect cursor to initialize rest of store
        if (mem.eql(u8, self.root_path, path)) {
            var children: []Entry = undefined;
            children.ptr = @ptrCast(self.root_entry_ptr);
            children.len = 0;
            return Cursor{
                .store = self,
                .parent = self.root_entry_ptr,
                .parent_idx = ROOT_ENTRY_INDEX,
                .cur = self.root_entry_ptr,
                .cur_idx = ROOT_ENTRY_INDEX,
                .children = children,
                .children_next = 0,
                .depth = 0,
            };
        }
        return error.TODO;
    }

    pub fn alloc_entries(self: *FS_Store, count: u32) struct { entries: []Entry, start_index: u32 } {
        // TODO: free list

        // number of pages needed to hold all entries
        const pages: u32 = @intCast(@divTrunc((count * Entry.SIZE) + PAGE_SIZE - 1, PAGE_SIZE));
        // TODO: check we'ere under some high_water_mark or max file size
        std.debug.assert(self.extent + pages <= self.extent_max);

        // TODO: madvise MADV_SEQUENTIAL & MADV_WILLNEED

        // all children slices start at a page aligned offset
        const page_start = self.extent;
        self.extent += pages;
        // convert page index to index within entries
        const start_index: u32 = @intCast((page_start - HEADER_PAGES_COUNT) * ENTRIES_PER_PAGE);
        const entries: []Entry = self.entries[start_index..][0..count];
        {
            const entries_ptr_expected = @intFromPtr(@as([*]Entry, @ptrCast(self.ptr + (page_start * PAGE_SIZE))));
            const entries_ptr_actual = @intFromPtr(@as([*]Entry, @ptrCast(entries.ptr)));
            std.debug.assert(entries_ptr_actual == entries_ptr_expected);
        }
        return .{
            .entries = entries,
            .start_index = start_index,
        };
    }

    pub const Entry = extern struct {
        parent: u32 align(1),
        children_start: u32 align(1),
        children_count: u32 align(1),
        _unused_but_should_be_inode: u32 align(1),
        byte_count: u64 align(1),
        block_count: u64 align(1),
        mtime: u64 align(1),
        lock_this: u8 align(1),
        lock_child: u8 align(1),
        kind: u8 align(1),
        name_len: u8 align(1),
        _reserved: [212]u8 align(1),
        name: [NAME_LEN_MAX + 1]u8 align(1),

        // TODO: link to article saying linux names can only be 255 bytes
        pub const NAME_LEN_MAX = 255;
        pub const SIZE = 512;

        pub const FileKind = enum(u8) {
            dir = 0,
            file = 1,
            link_soft = 2,
            link_hard = 3,
            unknown = 4,
        };
    };

    comptime {
        if (@sizeOf(Entry) != Entry.SIZE) {
            @compileError("Expected @sizeOf(FS_Store.Entry) to be 512B, got " ++ std.fmt.comptimePrint("{d}B", .{@sizeOf(Entry)}));
        }
    }

    pub const Cursor = struct {
        store: *FS_Store,
        parent: *Entry,
        parent_idx: u32,
        cur: *Entry,
        cur_idx: u32,
        children: []Entry,
        children_next: u32,
        depth: u32,

        pub fn recurse_into(self: *Cursor, path: []const u8) !void {
            if (&self.children.ptr[0] == self.cur) {
                return error.Empty;
            }
            if (self.children_next < self.children.len) {
                return error.NotFull;
            }
            if (path.len > Entry.NAME_LEN_MAX) {
                return error.PathToLong;
            }

            // TODO: update all parents sizes here because this means we finished processing all of this directories files

            const dest: *Entry, const dest_idx: u32 = dest: for (self.children, self.cur.children_start..) |*child, idx| {
                // PERF: take inode and match that first (linux no entries within same dir have same inode ???)
                if (mem.eql(u8, path, child.name[0..child.name_len])) {
                    break :dest .{ child, @intCast(idx) };
                }
            } else return error.ChildNotFound;

            if (dest.kind != @intFromEnum(Entry.FileKind.dir)) {
                return error.NotDir;
            }

            self.parent = self.cur;
            // FIXME: self.cur_idx
            self.parent_idx = self.cur_idx;
            self.cur = dest;
            self.cur_idx = dest_idx;
            self.children.ptr = @ptrCast(dest);
            self.children.len = 0;
            self.children_next = 0;
            self.depth += 1;
        }

        pub fn backtrack(self: *Cursor, path: []const u8) void {
            std.debug.assert(self.children.len == self.children_next);
            std.debug.assert(self.cur != self.store.root_entry_ptr); // cannot backtrack from root

            // std.debug.assert(self.children.len == 0 or &self.children.ptr[0] != self.cur);
            std.debug.assert(mem.eql(u8, self.parent.name[0..self.parent.name_len], path));

            @atomicStore(u8, &self.cur.lock_this, 1, .release);

            // TODO: put behind is_new flag
            {
                self.parent.block_count += self.cur.block_count;
                self.parent.byte_count += self.cur.byte_count;
            }

            if (self.parent_idx == ROOT_ENTRY_INDEX) {
                self.cur_idx = ROOT_ENTRY_INDEX;
                self.cur = self.store.root_entry_ptr;
                self.parent_idx = ROOT_ENTRY_INDEX;
                self.parent = self.store.root_entry_ptr;
                self.children = self.store.entries[self.cur.children_start..][0..self.cur.children_count];
                self.children_next = self.cur.children_count;
                self.depth = 0;
                return;
            }

            const grandparent_idx = self.parent.parent;
            const grandparent = if (grandparent_idx == ROOT_ENTRY_INDEX) self.store.root_entry_ptr else &self.store.entries[grandparent_idx];
            const parent = self.parent;
            const parent_idx = self.parent_idx;

            self.cur = parent;
            self.cur_idx = parent_idx;
            self.parent = grandparent;
            self.parent_idx = grandparent_idx;
            self.children = self.store.entries[parent.children_start..][0..parent.children_count];
            self.children_next = parent.children_count;
            self.depth -= 1;

            // TODO: update all parents sizes here if child.children_count == 0
            // because we won't update parents when recursing because we didn't recurse!
        }

        pub fn children_begin(self: *Cursor, count: u32) void {
            // if it doesn't then we already called children_begin
            std.debug.assert(&self.children.ptr[0] == self.cur);
            const children = self.store.alloc_entries(count);
            self.children = children.entries;
            self.cur.children_count = count;
            self.cur.children_start = children.start_index;
        }

        pub fn children_end(self: *Cursor) void {
            std.debug.assert(self.children_next == self.children.len);
            @atomicStore(u8, &self.cur.lock_this, 0, .release);
        }

        pub fn child_init(
            self: *Cursor,
        ) *Entry {
            std.debug.assert(self.children_next < self.children.len);
            const ptr = &self.children[self.children_next];
            ptr.lock_this = 1;
            // FIXME: self.cur_idx
            ptr.parent = self.cur_idx;
            return ptr;
        }

        pub fn child_finish(self: *Cursor) void {
            const child = self.children[self.children_next];
            if (child.kind != @intFromEnum(Entry.FileKind.dir)) {
                self.parent.byte_count += child.byte_count;
                self.parent.block_count += child.block_count;
            }
            self.children_next += 1;
        }
    };
};
