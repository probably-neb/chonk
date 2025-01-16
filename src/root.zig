const std = @import("std");
const testing = std.testing;
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
    };
}

pub const FileSizeEntry = struct {
    size: u64,
    abs_path: std.BoundedArray(u8, std.fs.max_path_bytes),
};

const fts = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fts.h");
});

pub fn index_paths_starting_with(root_path: []const u8, base_alloc: Allocator, dir_queue: *DirQueue, running: *const std.Thread.ResetEvent, connection_pool: *sqlite.Pool, files_indexed: *u64, trickle_queue: *AtomicQueue(FileSizeEntry)) void {
    std.debug.print("INDEX START : {s}\n", .{root_path});
    const fs = std.fs;
    defer base_alloc.free(root_path);

    var arena = std.heap.ArenaAllocator.init(base_alloc);
    const alloc = arena.allocator();
    defer arena.deinit();

    const conn = connection_pool.acquire();
    defer connection_pool.release(conn);

    if (!fs.path.isAbsolute(root_path)) {
        std.debug.print("WARN: NOT ABSOLUTE: '{s}'\n", .{root_path});
        return;
    }

    _ = dir_queue;
    _ = running;

    const root_dir_z = alloc.dupeZ(u8, root_path) catch return;
    const path_args: [2][*c]u8 = .{ root_dir_z, @ptrFromInt(0) };

    const state: *fts.FTS = fts.fts_open(&path_args, fts.FTS_PHYSICAL, null);

    defer _ = fts.fts_close(state);

    var save_queue = std.ArrayList(DB.Entry).initCapacity(alloc, DB.ENTRY_SAVE_BATCH_COUNT * 2) catch return;

    var fts_entry: ?*fts.FTSENT = fts.fts_read(state);
    while (fts_entry) |fts_ent| : (fts_entry = fts.fts_read(state)) {
        // _ = @atomicRmw(u64, files_indexed, .Add, 1, .monotonic);
        files_indexed.* += 1;

        save_queue.append(switch (fts_ent.fts_info) {
            fts.FTS_D => .{
                .kind = .dir,
                .abs_path = alloc.dupe(u8, @as([*:0]u8, fts_ent.fts_path)[0..fts_ent.fts_pathlen]) catch continue,
                .size_bytes = 0,
            },
            fts.FTS_F => .{
                .kind = .file,
                .abs_path = alloc.dupe(u8, @as([*:0]u8, fts_ent.fts_path)[0..fts_ent.fts_pathlen]) catch continue,
                .size_bytes = if (@as(?*fts.struct_stat, fts_ent.fts_statp)) |stat| @intCast(stat.st_size) else 0,
            },
            fts.FTS_SL => .{
                .kind = .link_soft,
                .abs_path = alloc.dupe(u8, @as([*:0]u8, fts_ent.fts_path)[0..fts_ent.fts_pathlen]) catch continue,
                .size_bytes = 0,
            },
            else => continue,
        }) catch continue;
        // std.debug.print("CHILD: PATH={s} NAME={s}\n", .{ @as([*:0]u8, fts_ent.fts_path), @as([*:0]u8, @ptrCast(&fts_ent.fts_name)) });

        while (save_queue.items.len >= DB.ENTRY_SAVE_BATCH_COUNT) {
            const batch: *const [DB.ENTRY_SAVE_BATCH_COUNT]DB.Entry = &save_queue.items[0..DB.ENTRY_SAVE_BATCH_COUNT].*;
            DB.entries_save_batch(conn, batch) catch continue;
            for (batch) |entry| {
                if (entry.kind == .file) {
                    var node: *AtomicQueue(FileSizeEntry).Node = trickle_queue.pool.create() catch continue;
                    node.value.abs_path.resize(0) catch unreachable;
                    node.value.abs_path.appendSlice(entry.abs_path) catch unreachable;
                    node.value.size = entry.size_bytes;
                    trickle_queue.push(node);
                }
            }
            save_queue.replaceRange(0, DB.ENTRY_SAVE_BATCH_COUNT, &.{}) catch continue;
        }
    }
    std.debug.print("EXITING\n", .{});
    for (save_queue.items) |entry| {
        DB.entries_save_one(conn, entry) catch continue;
    }
    for (save_queue.items) |entry| {
        if (entry.kind == .file) {
            var node: *AtomicQueue(FileSizeEntry).Node = trickle_queue.pool.create() catch continue;
            node.value.abs_path.resize(0) catch unreachable;
            node.value.abs_path.appendSlice(entry.abs_path) catch unreachable;
            node.value.size = entry.size_bytes;
            trickle_queue.push(node);
        }
    }

    // const root_dir = fs.openDirAbsolute(root_path, .{
    //     .iterate = true,
    // }) catch {
    //     return;
    // };
    //
    // var queue = std.ArrayList(fs.Dir).initCapacity(alloc, 4096) catch {
    //     return;
    // };
    //
    // queue.append(root_dir) catch return;
    //
    // var save_queue = std.ArrayList(DB.Entry).initCapacity(alloc, DB.ENTRY_SAVE_BATCH_COUNT * 2) catch return;
    //
    _ = std.fs.Dir.Entry;
    //
    // // defer std.debug.print("worker thread go die\n", .{});
    //
    // while (queue.popOrNull()) |dir| {
    //     if (!running.isSet()) {
    //         // NOTE: maybe should save already done work first?
    //         return;
    //     }
    //     var dir_iter = dir.iterate();
    //
    //     var file_sizes_total: u64 = 0;
    //     var file_sizes_path: []const u8 = &.{};
    //
    //     while (dir_iter.next() catch null) |entry| {
    //         defer files_indexed.* += 1;
    //         switch (entry.kind) {
    //             .directory => {
    //                 // std.debug.print("Found Path {s} TYPE=DIR\n", .{entry.name});
    //                 const path = dir.realpathAlloc(alloc, entry.name) catch continue;
    //                 save_queue.append(.{
    //                     .abs_path = path,
    //                     .size_bytes = 0,
    //                     .kind = .dir,
    //                 }) catch continue;
    //                 // const sub_dir = fs.openDirAbsolute(path, .{
    //                 //     .iterate = true,
    //                 // }) catch |err| {
    //                 //     std.debug.print("ERROR: failed to recurse into dir: '{s}' reason: {any}\n", .{ path, err });
    //                 //     continue;
    //                 // };
    //                 // try queue.append(sub_dir);
    //                 dir_queue.enqueue(path) catch return;
    //                 // pool.spawn(index_paths_starting_with, .{
    //                 //     path, pool, connection_pool, files_indexed,
    //                 // }) catch |err| {
    //                 //     std.debug.print("ERROR: failed to recurse into dir: '{s}' reason: {any}\n", .{ path, err });
    //                 //     continue;
    //                 // };
    //             },
    //             .file => {
    //                 // std.debug.print("Found Path {s} TYPE=DIR\n", .{entry.name});
    //                 const path = dir.realpathAlloc(alloc, entry.name) catch return;
    //                 const size = blk: {
    //                     const file = dir.openFile(entry.name, .{
    //                         .mode = .read_only,
    //                     }) catch continue;
    //                     const size = (file.stat() catch continue).size;
    //                     break :blk size;
    //                 };
    //                 save_queue.append(.{
    //                     .abs_path = path,
    //                     .size_bytes = size,
    //                     .kind = .file,
    //                 }) catch continue;
    //                 file_sizes_total += size;
    //                 file_sizes_path = path;
    //             },
    //             // TODO: links
    //             else => continue,
    //         }
    //     }
    //
    //     if (file_sizes_total > 0) {
    //         DB.update_parent_sizes_of(conn, file_sizes_path, file_sizes_total) catch return;
    //     }
    //     while (save_queue.items.len >= DB.ENTRY_SAVE_BATCH_COUNT) {
    //         const batch: *const [DB.ENTRY_SAVE_BATCH_COUNT]DB.Entry = &save_queue.items[0..DB.ENTRY_SAVE_BATCH_COUNT].*;
    //         DB.entries_save_batch(conn, batch) catch continue;
    //         save_queue.replaceRange(0, DB.ENTRY_SAVE_BATCH_COUNT, &.{}) catch continue;
    //     }
    // }
    // while (save_queue.items.len >= DB.ENTRY_SAVE_BATCH_COUNT) {
    //     const batch: *const [DB.ENTRY_SAVE_BATCH_COUNT]DB.Entry = &save_queue.items[0..DB.ENTRY_SAVE_BATCH_COUNT].*;
    //     DB.entries_save_batch(conn, batch) catch continue;
    //     save_queue.replaceRange(0, DB.ENTRY_SAVE_BATCH_COUNT, &.{}) catch break;
    // }
    // for (save_queue.items) |entry| {
    //     DB.entries_save_one(conn, entry) catch continue;
    // }
    return;
}

pub fn trickle_up_file_sizes(connection_pool: *sqlite.Pool, trickle_queue: *AtomicQueue(FileSizeEntry)) void {
    // FIXME: KILL THIS THREAD
    while (true) {
        std.atomic.spinLoopHint();
        if (trickle_queue.pop()) |node| {
            const conn = connection_pool.acquire();
            defer connection_pool.release(conn);
            const path = node.value.abs_path.slice();
            std.debug.print("trickling :: {s}\n", .{path});
            DB.update_parent_sizes_of(conn, path, node.value.size) catch continue;
        }
    }
}
