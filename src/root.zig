const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub fn get_top_level_paths(alloc: Allocator) ![][:0]const u8 {
    const files = [2][:0]const u8{
        "/home/neb/",
        "/",
    };
    var file_list = std.ArrayList([:0]const u8).init(alloc);
    try file_list.appendSlice(&files);
    return file_list.items;
}
