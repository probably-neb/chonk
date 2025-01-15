const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const sqlite = @import("zqlite");

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

    pub fn connect(alloc: Allocator) !sqlite.Conn {
        const db_name = "chonk.sqlite3.db";

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

        const flags = sqlite.OpenFlags.Create | sqlite.OpenFlags.EXResCode;
        return sqlite.open(path, flags);
    }

    pub fn ensure_init(conn: sqlite.Conn) !void {
        try conn.execNoArgs(
            \\create table if not exists paths (
            \\    id integer primary key autoincrement,
            \\    path text not null,
            \\    size_bytes integer not null default 0,
            \\    type int check(type in (0, 1, 2, 3)) not null,
            \\    parent_id integer references paths(id) default null
            \\)
        );
    }
};
