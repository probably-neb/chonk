const clay = @import("clay");
const DirEntry = @import("bin").DirEntry;

const ClayCustom = union(enum) {
    none: void,
    squarified_treemap: struct {
        dir_entries: []const DirEntry,
    },

    const NONE: ClayCustom = .{ .none = {} };

    pub fn noneConfig() clay.ElementDeclaration {
        return .{ .custom = .{ .custom_data = @ptrCast(@constCast(&NONE)) } };
    }
};
