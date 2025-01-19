const std = @import("std");
const print = std.debug.print;

const fts = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fts.h");
});

pub fn main() !void {
    const root_path: [:0]const u8 = "/home/neb/code/chonk/tests/test-root/";

    const alloc = std.heap.page_allocator;

    const path_args: [2][*c]u8 = .{ @ptrCast(@constCast(root_path)), @ptrFromInt(0) };

    const state: *fts.FTS = fts.fts_open(&path_args, fts.FTS_PHYSICAL, null);
    defer _ = fts.fts_close(state);

    print("INDEX START : {s}\n", .{root_path});

    var fts_entry: ?*fts.FTSENT = fts.fts_read(state);

    var prev_path: []const u8 = try alloc.dupe(u8, root_path);

    while (fts_entry) |fts_ent| : (fts_entry = fts.fts_read(state)) {
        const path = try alloc.dupe(u8, @as([*]u8, @ptrCast(fts_ent.fts_path))[0..fts_ent.fts_pathlen]);
        defer {
            alloc.free(prev_path);
            prev_path = path;
        }
        // files_indexed.* += 1;
        const name = @as([*]u8, @ptrCast(&fts_ent.fts_name))[0..fts_ent.fts_namelen];

        switch (fts_ent.fts_info) {
            fts.FTS_D, fts.FTS_F, fts.FTS_SL => |val| {
                print("VISITING {s} '{s}'\n", .{
                    switch (val) {
                        fts.FTS_D => "[dir] ",
                        fts.FTS_F => "[file]",
                        fts.FTS_SL => "[link]",
                        else => unreachable,
                    },
                    path,
                });
            },
            fts.FTS_DP => {
                // TODO: use variables left in FTENT structure for user use to keep track of child index and
                // create backtrack_index fn to avoid search
                print("BACKTRACKING FROM '{s}' -> '{s}' [name={s}]\n", .{ prev_path, path, name });
                continue;
            },
            else => {
                // TODO: handle errors
                continue;
            },
        }
        const children: ?*fts.FTSENT = fts.fts_children(state, 0);

        var child = children;
        var count: u32 = 0;
        while (child) |c| : (count += 1) {
            child = c.fts_link;
        }

        while (child) |c| {
            defer child = c.fts_link;
            // TODO: simd kind getting
            // var kind: FS_Store.Entry.FileKind = undefined;
            //
            // switch (c.fts_info) {
            //     fts.FTS_D => kind = .dir,
            //     fts.FTS_F => kind = .file,
            //     fts.FTS_SL => kind = .link_soft, // TODO: ensure proper handling of hard/soft link sizes
            //     fts.FTS_DP => {
            //         unreachable;
            //     },
            //     else => {
            //         // TODO: handle errors
            //         continue;
            //     },
            // }

            // TODO: inode

            const child_name = @as([*]u8, @ptrCast(&c.fts_name))[0..c.fts_namelen];
            print("CHILD NAME = {s}\n", .{child_name});
        }
    }

    return;
}
