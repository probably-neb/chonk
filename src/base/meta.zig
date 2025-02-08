const std = @import("std");

pub fn has_field_of_type(comptime T: type, comptime field_name: []const u8, comptime ExpectedType: type) bool {
    const fields = switch (@typeInfo(T)) {
        .@"struct" => |s| s.fields,
        .@"union" => |u| u.fields,
        else => @compileError("has_field_of_type requires a struct or union type"),
    };

    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.type == ExpectedType;
        }
    }

    return false;
}

test has_field_of_type {
    const Point = struct {
        x: i32,
        y: i32,
        name: []const u8,
    };

    try std.testing.expect(has_field_of_type(Point, "x", i32));
    try std.testing.expect(has_field_of_type(Point, "y", i32));
    try std.testing.expect(has_field_of_type(Point, "name", []const u8));
    try std.testing.expect(!has_field_of_type(Point, "x", u32));
    try std.testing.expect(!has_field_of_type(Point, "x", i64));
    try std.testing.expect(!has_field_of_type(Point, "y", f32));
    try std.testing.expect(!has_field_of_type(Point, "z", i32));
    try std.testing.expect(!has_field_of_type(Point, "nonexistent", u8));

    const Value = union {
        int: i64,
        float: f64,
        string: []const u8,
    };

    try std.testing.expect(has_field_of_type(Value, "int", i64));
    try std.testing.expect(has_field_of_type(Value, "float", f64));
    try std.testing.expect(has_field_of_type(Value, "string", []const u8));
    try std.testing.expect(!has_field_of_type(Value, "int", i32));
    try std.testing.expect(!has_field_of_type(Value, "float", f32));
}
