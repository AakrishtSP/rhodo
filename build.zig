const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Compile shaders
    const shaders = .{
        .{ "shaders/basic.vert.hlsl", "basic.vert.spv", "vs_6_0" },
        .{ "shaders/basic.frag.hlsl", "basic.frag.spv", "ps_6_0" },
    };
    const shader_step = b.step("shaders", "Compile HLSL shaders");
    inline for (shaders) |s| {
        const cmd = b.addSystemCommand(&.{
            "dxc",                             "-spirv",
            "-T",                              s[2],
            "-E",                              "main",
            s[0],                              "-Fo",
            b.pathJoin(&.{ "shaders", s[1] }),
        });
        shader_step.dependOn(&cmd.step);
    }

    const lib_mod = b.addModule("rhodo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const sandbox = b.addExecutable(.{
        .name = "rhodo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sandbox/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rhodo", .module = lib_mod },
            },
        }),
    });

    sandbox.step.dependOn(shader_step);

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    });

    b.installArtifact(sandbox);
    lib_mod.addImport("vulkan", vulkan.module("vulkan-zig"));
    lib_mod.addImport("sdl3", sdl3.module("sdl3"));
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(sandbox);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = sandbox.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
