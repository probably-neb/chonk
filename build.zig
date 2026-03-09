const std = @import("std");

const Module = struct {
    name: []const u8,
    exe_name: ?[]const u8 = null,
    mod: ?*std.Build.Module = null,
    exe: ?*std.Build.Step.Compile = null,
};

const mod_defs = [_]Module{
    .{ .name = "base" },
    .{ .name = "text" },
    .{ .name = "bin", .exe_name = "chonk" },
    .{ .name = "fs-index" },
    .{ .name = "ui" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests");
    const check_step = b.step("check", "Run all checks");

    var modules: [mod_defs.len]*std.Build.Module = undefined;
    var exes: [mod_defs.len]?*std.Build.Step.Compile = .{null} ** mod_defs.len;

    for (&mod_defs, 0..) |*mod_def, i| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}/{s}.zig", .{ mod_def.name, mod_def.name })),
            .target = target,
            .optimize = optimize,
        });
        modules[i] = mod;
        exes[i] = if (mod_def.exe_name) |name| b.addExecutable(.{
            .name = name,
            .root_module = mod,
        }) else null;
        const mod_test_step = b.addTest(.{
            .root_module = mod,
        });
        const run_test_cmd = b.addRunArtifact(mod_test_step);
        test_step.dependOn(&run_test_cmd.step);
        check_step.dependOn(&run_test_cmd.step);

        const test_mod = b.step(b.fmt("test:{s}", .{mod_def.name}), b.fmt("Run tests for {s}", .{mod_def.name}));
        test_mod.dependOn(&run_test_cmd.step);

        const check_exe = b.addExecutable(.{
            .name = b.fmt("check-{s}", .{mod_def.name}),
            .root_module = mod,
        });
        check_step.dependOn(&check_exe.step);
    }

    for (modules, 0..) |mod, i| {
        for (modules, mod_defs, 0..) |other_mod, other_mod_def, j| {
            if (i == j) {
                continue;
            }
            mod.addImport(other_mod_def.name, other_mod);
        }
    }

    {
        const raylib_dep = b.dependency("raylib-zig", .{
            .target = target,
            .optimize = optimize,
        });

        const raylib = raylib_dep.module("raylib"); // main raylib module
        const raygui = raylib_dep.module("raygui"); // raygui module
        const raylib_artifact = raylib_dep.artifact("raylib"); // raylib C library

        for (modules) |mod| {
            mod.linkLibrary(raylib_artifact);
            mod.addImport("raylib", raylib);
            mod.addImport("raygui", raygui);
        }
    }
    {
        const zclay_dep = b.dependency("clay", .{
            .target = target,
            .optimize = optimize,
        });

        for (modules) |mod| {
            mod.addImport("clay", zclay_dep.module("zclay"));
        }
    }
    {
        const freetype_dep = b.dependency("mach-freetype", .{
            .target = target,
            .optimize = optimize,
            .enable_brotli = false,
        });

        for (modules) |mod| {
            mod.addImport("freetype", freetype_dep.module("mach-freetype"));
            mod.addImport("harfbuzz", freetype_dep.module("mach-harfbuzz"));
        }
    }
    for (modules) |mod| {
        mod.addAnonymousImport("FiraSans-Regular.ttf", .{
            .root_source_file = b.path("src/assets/fonts/FiraSans-Regular.ttf"),
        });
    }

    for (exes) |exe| {
        if (exe) |executable| {
            const install_step = b.addInstallArtifact(executable, .{});
            const run_cmd = b.addRunArtifact(executable);

            run_cmd.step.dependOn(&install_step.step);
            b.installArtifact(executable);

            if (b.args) |args| {
                run_cmd.addArgs(args);
            }

            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&run_cmd.step);
        }
    }
}
