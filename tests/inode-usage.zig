const std = @import("std");

const c = @cImport(@cInclude("sys/vfs.h"));

pub fn main() !void {
    const path: [:0]const u8 = "/";
    var fs_stats: c.struct_statfs = undefined;
    if (c.statfs(path, &fs_stats) < 0) {
        std.debug.panic("statfs failed: {}", .{@as(std.posix.E, @enumFromInt(std.c._errno().*))});
    }
    std.debug.print("fs_stats: {any}\n", .{fs_stats});
    const count_inodes = fs_stats.f_files - fs_stats.f_ffree;
    std.debug.print("used inodes: {}\n", .{count_inodes});
}
