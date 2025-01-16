const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

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
        try conn.execNoArgs(
            \\create table if not exists paths (
            \\    id integer primary key autoincrement,
            \\    path text not null UNIQUE,
            \\    size_bytes integer not null default 0,
            \\    type int check(type in (0, 1, 2, 3)) not null,
            \\    parent_id integer references paths(id) default null
            \\)
        );
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

    const ENTRY_SAVE_BATCH_COUNT = 32;

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

        inline for (batch_flat) |item| {
            std.debug.print("\t{s}\n", .{@tagName(@typeInfo(@TypeOf(item)))});
        }

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

    pub fn entries_get_direct_children_of(conn: sqlite.Conn, alloc: Allocator, path: []const u8) ![]Entry {
        var entries = std.ArrayList(Entry).init(alloc);

        std.debug.assert(std.fs.path.isAbsolute(path));

        var rows = try conn.rows(
            \\ SELECT path, size_bytes, type FROM paths
            \\ WHERE paths.path LIKE (?) || '/%'
            \\ AND
            \\       paths.path NOT LIKE (?) || '/%/%';
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

pub fn index_paths_starting_with(root_path: []const u8, mutex: *std.Thread.Mutex, connection_pool: *sqlite.Pool) !void {
    const fs = std.fs;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const conn = connection_pool.acquire();
    defer connection_pool.release(conn);

    std.debug.assert(fs.path.isAbsolute(root_path));

    const root_dir = try fs.openDirAbsolute(root_path, .{
        .iterate = true,
    });

    var queue = try std.ArrayList(fs.Dir).initCapacity(alloc, 4096);

    try queue.append(root_dir);

    var save_queue = try std.ArrayList(DB.Entry).initCapacity(alloc, DB.ENTRY_SAVE_BATCH_COUNT * 2);

    _ = std.fs.Dir.Entry;

    defer std.debug.print("worker thread go die\n", .{});

    while (queue.popOrNull()) |dir| {
        if (mutex.tryLock()) {
            // NOTE: maybe should save already done work first?
            mutex.unlock();
            return;
        }
        var dir_iter = dir.iterate();
        while (dir_iter.next() catch null) |entry| {
            switch (entry.kind) {
                .directory => {
                    std.debug.print("Found Path {s} TYPE=DIR\n", .{entry.name});
                    const path = try dir.realpathAlloc(alloc, entry.name);
                    try save_queue.append(.{
                        .abs_path = path,
                        .size_bytes = 0,
                        .kind = .dir,
                    });
                },
                .file => {
                    std.debug.print("Found Path {s} TYPE=DIR\n", .{entry.name});
                    const path = try dir.realpathAlloc(alloc, entry.name);
                    const size = blk: {
                        const file = try dir.openFile(entry.name, .{
                            .mode = .read_only,
                        });
                        const size = (try file.stat()).size;
                        break :blk size;
                    };
                    try save_queue.append(.{
                        .abs_path = path,
                        .size_bytes = size,
                        .kind = .file,
                    });
                },
                // TODO: links
                else => continue,
            }
        }

        while (save_queue.items.len >= DB.ENTRY_SAVE_BATCH_COUNT) {
            const batch: *const [DB.ENTRY_SAVE_BATCH_COUNT]DB.Entry = &save_queue.items[0..DB.ENTRY_SAVE_BATCH_COUNT].*;
            for (batch) |entry| {
                try DB.entries_save_one(conn, entry);
            }
            try save_queue.replaceRange(0, DB.ENTRY_SAVE_BATCH_COUNT, &.{});
        }
    }
    while (save_queue.items.len >= DB.ENTRY_SAVE_BATCH_COUNT) {
        const batch: *const [DB.ENTRY_SAVE_BATCH_COUNT]DB.Entry = &save_queue.items[0..DB.ENTRY_SAVE_BATCH_COUNT].*;
        for (batch) |entry| {
            try DB.entries_save_one(conn, entry);
        }
        try save_queue.replaceRange(0, DB.ENTRY_SAVE_BATCH_COUNT, &.{});
    }
    for (save_queue.items) |entry| {
        try DB.entries_save_one(conn, entry);
    }
    return;
}
