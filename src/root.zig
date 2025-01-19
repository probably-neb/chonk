const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

pub const sqlite = @import("zqlite");

pub const TopLevelPath = struct {
    path: [:0]const u8,
    device: ?[:0]const u8 = null,
};

pub fn get_top_level_paths(alloc: Allocator, scratch: Allocator) ![]TopLevelPath {
    var file_list = std.ArrayList(TopLevelPath).init(alloc);

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

pub const DB = struct {
    pub const FileKind = enum(u8) {
        dir = 0,
        file = 1,
        link_soft = 2,
        link_hard = 3,
    };

    const db_name = "chonk.sqlite3.db";

    fn resolve_path(alloc: Allocator) ![:0]u8 {
        const path = if (@import("builtin").mode == .Debug) dir: {
            const dir = comptime std.fs.cwd();
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try dir.realpath(".", &buf);
            break :dir try std.fs.path.joinZ(alloc, &.{
                path,
                db_name,
            });
        } else {
            unreachable;
        };
        return path;
    }

    pub fn connect(alloc: Allocator) !sqlite.Conn {
        const path = try DB.resolve_path(alloc);

        const flags = sqlite.OpenFlags.Create | sqlite.OpenFlags.EXResCode;
        return sqlite.open(path, flags);
    }

    pub fn init_pool(alloc: Allocator, count: usize) !*sqlite.Pool {
        const path = try DB.resolve_path(alloc);
        const pool = try sqlite.Pool.init(alloc, .{
            .path = path,
            .flags = sqlite.OpenFlags.Create | sqlite.OpenFlags.EXResCode,
            .size = count,
        });
        return pool;
    }

    pub fn ensure_init(conn: sqlite.Conn) !void {
        try conn.execNoArgs(
            \\ PRAGMA journal_mode=WAL;        
        );
        if (@import("builtin").mode == .Debug) {
            try conn.execNoArgs("drop table if exists paths;");
        }
        try conn.execNoArgs(
            \\create table if not exists paths (
            \\    id integer primary key autoincrement,
            \\    path text not null UNIQUE,
            \\    size_bytes integer not null default 0,
            \\    type int check(type in (0, 1, 2, 3)) not null,
            \\    parent_id integer references paths(id) default null
            \\)
        );
        const indexes = .{
            // Index for path pattern matching
            \\ CREATE INDEX IF NOT EXISTS idx_paths_path 
            \\ ON paths(path);
            ,
            // Composite index for path + type combination
            \\ CREATE INDEX IF NOT EXISTS idx_paths_path_type 
            \\ ON paths(path, type);
            ,
            // Index specifically for type field since we filter on it
            \\ CREATE INDEX IF NOT EXISTS idx_paths_type 
            \\ ON paths(type);
            ,
            // Index for size_bytes to help with sorting and summation
            \\ CREATE INDEX IF NOT EXISTS idx_paths_size 
            \\ ON paths(size_bytes);
            ,
            // Composite index that might help with the common combination
            \\ CREATE INDEX IF NOT EXISTS idx_paths_type_size 
            \\ ON paths(type, size_bytes);
            ,
        };
        inline for (indexes) |index| {
            try conn.execNoArgs(index);
        }
    }

    pub const Entry = struct {
        abs_path: []const u8,
        size_bytes: u64,
        kind: FileKind,

        pub const fields = std.meta.fields(@This());
        pub const field_type_array = blk: {
            var array: [fields.len]type = undefined;
            for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, "kind")) {
                    array[i] = u8;
                } else {
                    array[i] = field.type;
                }
            }
            break :blk array;
        };
    };

    const ENTRY_SAVE_BATCH_COUNT = 64;

    pub fn entries_save_batch(conn: sqlite.Conn, batch: *const [ENTRY_SAVE_BATCH_COUNT]Entry) !void {
        const BatchFlat = std.meta.Tuple(&(Entry.field_type_array ** ENTRY_SAVE_BATCH_COUNT));
        var batch_flat: BatchFlat = undefined;

        inline for (0..ENTRY_SAVE_BATCH_COUNT) |i| {
            inline for (Entry.fields, 0..) |field, f| {
                const batch_flat_field_name = std.fmt.comptimePrint("{d}", .{i * Entry.field_type_array.len + f});

                if (comptime std.mem.eql(u8, field.name, "kind")) {
                    @field(batch_flat, batch_flat_field_name) = @intFromEnum(batch[i].kind);
                } else {
                    @field(batch_flat, batch_flat_field_name) = @field(
                        batch[i],
                        field.name,
                    );
                }
            }
        }

        // inline for (batch_flat) |item| {
        //     std.debug.print("\t{s}\n", .{@tagName(@typeInfo(@TypeOf(item)))});
        // }

        const query = std.fmt.comptimePrint(
            \\ INSERT INTO paths (path, size_bytes, type) values
            \\ {s}{s}
            \\ ON CONFLICT (path)
            \\ DO UPDATE SET
            \\      type = excluded.type,
            \\      size_bytes = excluded.size_bytes;
            \\
        , .{
            "((?), (?), (?)), " ** (DB.ENTRY_SAVE_BATCH_COUNT - 1),
            "((?), (?), (?))",
        });

        try conn.exec(query, batch_flat);
    }

    pub fn entries_save_one(conn: sqlite.Conn, entry: Entry) !void {
        try conn.exec(
            \\ INSERT INTO paths (path, size_bytes, type) values
            \\ ((?), (?), (?))
            \\ ON CONFLICT (path)
            \\ DO UPDATE SET
            \\      type = excluded.type,
            \\      size_bytes = excluded.size_bytes;
            \\
        , .{
            entry.abs_path,
            entry.size_bytes,
            @as(u8, @intFromEnum(entry.kind)),
        });
    }

    pub fn update_parent_sizes_of(conn: sqlite.Conn, path: []const u8, size: u64) !void {
        try conn.exec(
            \\ UPDATE paths
            \\ SET size_bytes = size_bytes + (?)
            \\ where (?) like path || '/%';
        , .{
            size,
            path,
        });
    }

    pub fn entries_get_direct_children_of(conn: sqlite.Conn, alloc: Allocator, path: []const u8) ![]Entry {
        var entries = std.ArrayList(Entry).init(alloc);

        std.debug.assert(std.fs.path.isAbsolute(path));

        var rows = try conn.rows(
            \\ SELECT 
            \\     path,
            \\     size_bytes,
            \\     type
            \\ FROM paths
            \\ WHERE
            \\     path LIKE (?) || '/%'
            \\     AND path NOT LIKE (?) || '/%/%'
            \\ ORDER BY size_bytes DESC;
        ,
            .{
                path,
                path,
            },
        );
        defer rows.deinit();
        while (rows.next()) |row| {
            var entry: Entry = undefined;
            entry.abs_path = try alloc.dupe(u8, row.text(0));
            entry.size_bytes = @intFromFloat(row.float(1));
            entry.kind = @enumFromInt(@as(u8, @intCast(row.int(2))));
            try entries.append(entry);
        }
        if (rows.err) |err| {
            return err;
        }

        // WARN: memory leak
        return entries.items;
    }
};

pub const DirQueue = struct {
    items: std.ArrayList(Item),
    mutex: std.Thread.Mutex,
    alloc: Allocator,

    const Item = []const u8;

    pub fn init(self: *DirQueue, alloc: Allocator, init_capacity: usize) !void {
        self.* = DirQueue{
            .items = try std.ArrayList(Item).initCapacity(alloc, init_capacity),
            .alloc = alloc,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn enqueue(self: *DirQueue, item: Item) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.items.append(try self.alloc.dupe(u8, item));
    }

    pub fn enqueue_batch(self: *DirQueue, items: []Item) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const items_dupe = try self.alloc.dupe(Item, items);
        for (items, items_dupe) |item, *item_dupe| {
            item_dupe.* = try self.alloc.dupe(u8, item);
        }

        try self.items.appendSlice(items_dupe);
    }

    pub fn empty(self: *DirQueue, alloc: Allocator) ![]Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = try alloc.dupe(Item, self.items.items);
        for (self.items.items, result) |item, *item_dupe| {
            item_dupe.* = try alloc.dupe(u8, item);
            self.alloc.free(item);
        }
        self.items.resize(0) catch unreachable;
        return result;
    }

    pub fn deinit(self: *DirQueue) void {
        self.items.deinit();
    }
};

pub fn AtomicQueue(comptime T: type) type {
    return struct {
        const Node = struct {
            next: ?*Node,
            value: T,
        };

        // TODO: remove Atomic in favor of mutex
        head: ?*Node,
        tail: ?*Node,
        pool: std.heap.MemoryPool(Node),
        mutex: std.Thread.Mutex,

        pub fn init(self: *@This()) void {
            self.* = .{
                .head = null,
                .tail = null,
                .pool = std.heap.MemoryPool(Node).init(std.heap.page_allocator),
                .mutex = .{},
            };
        }

        pub fn deinit(self: *@This()) void {
            self.pool.deinit();
        }

        pub fn push(self: *@This(), node: *Node) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            node.next = null;
            if (self.tail) |t| {
                t.next = node;
                self.tail = node;
            } else if (self.head) |h| {
                h.next = node;
                self.tail = node;
            } else {
                self.head = node;
            }
        }

        pub fn pop(self: *@This()) ?*Node {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.head) |h| {
                self.head = h.next;
                if (self.head == self.tail) {
                    self.tail = null;
                }
                return h;
            }
            return null;
        }

        pub fn try_pop(self: *@This()) ?*Node {
            if (!self.mutex.tryLock()) {
                return null;
            }
            defer self.mutex.unlock();

            if (self.head) |h| {
                self.head = h.next;
                if (self.head == self.tail) {
                    self.tail = null;
                }
                return h;
            }
            return null;
        }
    };
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

pub fn index_paths_starting_with(root_path: [:0]const u8, base_alloc: Allocator, store: *FS_Store, files_indexed: *u64) void {
    _ = base_alloc;
    const fs = std.fs;
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

    std.debug.print("INDEX START : {s}\n", .{root_path});

    var cursor: FS_Store.Cursor = store.new_cursor_at(root_path) catch |err| {
        std.debug.print("Failed to init cursor at {s} :: {}\n", .{ root_path, err });
        return;
    };

    var fts_entry: ?*fts.FTSENT = fts.fts_read(state);

    var prev_path: []const u8 = root_path;

    while (fts_entry) |fts_ent| : (fts_entry = fts.fts_read(state)) {
        _ = @atomicRmw(u64, files_indexed, .Add, 1, .monotonic);
        const path = @as([*]u8, @ptrCast(fts_ent.fts_path))[0..fts_ent.fts_pathlen];
        std.debug.print("VISITING '{s}' [cursor_name={s}]\n", .{ path, cursor.cur.name[0..cursor.cur.name_len] });
        defer prev_path = path;
        // files_indexed.* += 1;
        const name = @as([*]u8, @ptrCast(&fts_ent.fts_name))[0..fts_ent.fts_namelen];

        switch (fts_ent.fts_info) {
            fts.FTS_D => {},
            fts.FTS_F, fts.FTS_SL => continue, // handled by children call
            fts.FTS_DP => {
                // TODO: use variables left in FTENT structure for user use to keep track of child index and
                // create backtrack_index fn to avoid search
                std.debug.print("BACKTRACKING FROM '{s}' -> '{s}' [name={s}] [cursor_name={s}]\n", .{ prev_path, path, name, cursor.cur.name[0..cursor.cur.name_len] });
                cursor.backtrack(name);
                continue;
            },
            else => {
                // TODO: handle errors
                continue;
            },
        }
        cursor.recurse_into(name) catch {
            // TODO: error
            continue;
        };
        if (true) {
            return;
        }
        const children: ?*fts.FTSENT = fts.fts_children(state, 0);

        var child = children;
        var count: u32 = 0;
        while (child) |c| : (count += 1) {
            child = c.fts_link;
        }

        cursor.children_begin(count);
        defer cursor.children_end();

        while (child) |c| {
            defer child = c.fts_link;
            // TODO: simd kind getting
            var kind: FS_Store.Entry.FileKind = undefined;

            switch (c.fts_info) {
                fts.FTS_D => kind = .dir,
                fts.FTS_F => kind = .file,
                fts.FTS_SL => kind = .link_soft, // TODO: ensure proper handling of hard/soft link sizes
                fts.FTS_DP => {
                    unreachable;
                },
                else => {
                    // TODO: handle errors
                    continue;
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
            std.debug.print("CHILD NAME = {s}\n", .{child_name});

            entry_ptr.byte_count = child_byte_count;
            entry_ptr.block_count = child_block_count;
            entry_ptr.kind = @intFromEnum(kind);
            @memcpy(&entry_ptr.name, child_name);
            entry_ptr.name[child_name.len] = 0;
            entry_ptr.name_len = @intCast(child_name.len);
        }
    }

    return;
}

pub fn trickle_up_file_sizes(connection_pool: *sqlite.Pool, trickle_queue: *AtomicQueue(FileSizeEntry)) void {
    // FIXME: KILL THIS THREAD
    while (true) {
        std.atomic.spinLoopHint();
        if (trickle_queue.try_pop()) |node| {
            const conn = connection_pool.acquire();
            defer connection_pool.release(conn);
            const path = node.value.abs_path.slice();
            std.debug.print("trickling :: {s}\n", .{path});
            DB.update_parent_sizes_of(conn, path, node.value.size) catch continue;
        }
    }
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
    extent: u32,
    extent_max: u32,

    const posix = std.posix;
    const PAGE_SIZE = std.mem.page_size;
    const MMAP_SIZE = PAGE_SIZE * 10_000; //6_000_000; // ~ 122GB of Virtual Address Space

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
        self.extent_max = @intCast(pages.len);
        {
            const root_entry: *Entry = @ptrCast(self.ptr + PAGE_SIZE - Entry.SIZE);
            root_entry.* = mem.zeroes(Entry);
            std.debug.assert(std.meta.fieldIndex(Entry, "name_len").? + 1 == std.meta.fieldIndex(Entry, "name").?);
            const name_len_ptr: *align(1) u16 = @ptrCast(&root_entry.name);
            name_len_ptr.* = @intCast(path.len);
            // TODO: use first page for metadata
            std.debug.assert(path.len < PAGE_SIZE - 1);
            @memcpy(self.ptr + PAGE_SIZE, path);
            self.ptr[PAGE_SIZE + path.len] = 0;
        }
        self.extent = 2;
    }

    fn resolve_path(alloc: Allocator) ![:0]u8 {
        const path = if (@import("builtin").mode == .Debug) dir: {
            const dir = comptime std.fs.cwd();
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try dir.realpath(".", &buf);
            break :dir try std.fs.path.joinZ(alloc, &.{
                path,
                "chonk.store",
            });
        } else {
            unreachable;
        };
        return path;
    }

    pub fn new_cursor_at(self: *FS_Store, path: []const u8) !Cursor {
        // TODO: look at root node at end of metadata page
        //       if root not empty => assert is subpath & recurse & find then initialize with partent etc
        //                    else => initialize root to be base path and expect cursor to initialize rest of store
        const root_entry: *Entry = @ptrCast(&self.ptr[PAGE_SIZE - Entry.SIZE]);
        const root_name_len_ptr: *align(1) u16 = @ptrCast(&root_entry.name);
        const root_name_len = root_name_len_ptr.*;
        const root_path: []const u8 = @as([*]const u8, @ptrCast(&self.ptr[PAGE_SIZE]))[0..root_name_len];
        if (mem.eql(u8, root_path, path)) {
            var children: []Entry = undefined;
            children.ptr = @ptrCast(root_entry);
            children.len = 0;
            return Cursor{
                .store = self,
                .parent = root_entry,
                .parent_idx = @divExact(PAGE_SIZE - Entry.SIZE, Entry.SIZE),
                .cur = root_entry,
                .children = children,
                .children_next = 0,
            };
        }
        return error.TODO;
    }

    pub fn alloc_entries(self: *FS_Store, count: u32) struct { ptr: []Entry, page_start: u32 } {
        // TODO: free list
        const ptr: [*]u8 = @ptrFromInt(@intFromPtr(self.ptr) + (self.extent * PAGE_SIZE));

        // get number of pages needed to hold all entries
        const pages = @divTrunc((count * Entry.SIZE) + PAGE_SIZE - 1, PAGE_SIZE);
        // TODO: check we'ere under some high_water_mark or max file size

        // TODO: madvise MADV_SEQUENTIAL & MADV_WILLNEED
        const page_start = self.extent;
        self.extent += pages;
        return .{ .ptr = @as([*]Entry, @ptrCast(ptr))[0..count], .page_start = page_start };
    }

    fn ptr_to_idx(self: *const FS_Store, ptr: anytype) u32 {
        // std.debug.assert(mem.alignPointer(ptr, PAGE_SIZE).? == ptr);
        return @intCast(@divExact(@intFromPtr(ptr) - @intFromPtr(self.ptr), PAGE_SIZE));
    }

    fn idx_to_ptr(self: *const FS_Store, idx: u32) [*]u8 {
        return @ptrCast(&self.ptr[idx * PAGE_SIZE]);
    }

    pub const Entry = extern struct {
        parent: u32 align(1),
        children_start: u32 align(1),
        children_count: u32 align(1),
        byte_count: u64 align(1),
        block_count: u64 align(1),
        mtime: u64 align(1),
        _unused_but_should_be_inode: u32 align(1),
        lock_this: u8 align(1),
        lock_child: u8 align(1),
        kind: u8 align(1),
        name_len: u8 align(1),
        name: [NAME_LEN_MAX + 1]u8 align(1),

        // TODO: link to article saying linux names can only be 255 bytes
        pub const NAME_LEN_MAX = 255;
        pub const SIZE = 512;

        pub const FileKind = enum(u8) {
            dir = 0,
            file = 1,
            link_soft = 2,
            link_hard = 3,
        };
    };

    comptime {
        if (@sizeOf(Entry) > Entry.SIZE) {
            @compileError("Expected @sizeOf(FS_Store.Entry) to be 512B, got " ++ std.fmt.comptimePrint("{d}B", .{@sizeOf(Entry)}));
        }
    }

    pub const Cursor = struct {
        store: *FS_Store,
        parent: *Entry,
        parent_idx: u32,
        cur: *Entry,
        children: []Entry,
        children_next: u32,

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

            const dest: *Entry = dest: for (self.children) |*child| {
                // PERF: take inode and match that first (linux no entries within same dir have same inode ???)
                if (mem.eql(u8, path, child.name[0..child.name_len])) {
                    break :dest child;
                }
            } else return error.ChildNotFound;

            if (dest.kind != @intFromEnum(Entry.FileKind.dir)) {
                return error.NotDir;
            }

            self.parent = self.cur;
            self.parent_idx = self.store.ptr_to_idx(self.cur);
            self.cur = dest;
            self.children.ptr = @ptrCast(dest);
            self.children.len = 0;
            self.children_next = 0;
        }

        pub fn backtrack(self: *Cursor, path: []const u8) void {
            std.debug.assert(self.children.len == self.children_next);
            // std.debug.assert(self.children.len == 0 or &self.children.ptr[0] != self.cur);
            const child = self.cur;
            self.cur = self.parent;
            std.debug.assert(mem.eql(u8, self.cur.name[0..self.cur.name_len], path) or mem.eql(u8, self.parent.name[0..self.parent.name_len], path));
            // TODO: put behind is_new flag
            {
                self.cur.block_count += child.block_count;
                self.cur.byte_count += child.byte_count;
            }
            self.parent_idx = self.cur.parent;
            self.parent = @ptrCast(@alignCast(self.store.idx_to_ptr(self.parent_idx)));
            self.children = @as([*]Entry, @ptrCast(self.store.idx_to_ptr(self.parent.children_start)))[0..self.parent.children_count];
            self.children_next = @intCast(self.children.len);

            // TODO: update all parents sizes here if child.children_count == 0
            // because we won't update parents when recursing because we didn't recurse!
        }

        pub fn children_begin(self: *Cursor, count: u32) void {
            // if it doesn't then we already called children_begin
            std.debug.assert(&self.children.ptr[0] == self.cur);
            const children = self.store.alloc_entries(count);
            self.children = children.ptr;
            self.parent.children_count = count;
            self.parent.children_start = children.page_start;
        }

        pub fn children_end(self: *Cursor) void {
            std.debug.assert(self.children_next == self.children.len);
        }

        pub fn child_init(
            self: *Cursor,
        ) *Entry {
            std.debug.assert(self.children_next < self.children.len);
            const ptr = &self.children[self.children_next];
            // FIXME: self.cur_idx
            ptr.parent = self.store.ptr_to_idx(self.cur);
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
