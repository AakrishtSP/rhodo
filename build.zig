const std = @import("std");

// Rhodo engine (library only). Games consume it as a dependency and own their
// app, shaders compilation, and assets — see the game repo. `zig build test`
// runs the engine unit tests (includes a headless Jolt sim test).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("rhodo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    lib_mod.link_libc = true;
    lib_mod.link_libcpp = true;
    lib_mod.addIncludePath(b.path("vendor/cgltf"));
    lib_mod.addCSourceFile(.{
        .file = b.path("vendor/cgltf/cgltf_impl.c"),
        .flags = &.{},
    });
    lib_mod.addIncludePath(b.path("vendor/stb"));
    lib_mod.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_impl.c"),
        .flags = &.{},
    });

    // Dear ImGui 1.92: core + SDL3/Vulkan backends from the imgui dep, C shim
    // from vendor/imgui. The Vulkan backend uses NO_PROTOTYPES + our loader
    // (we don't link libvulkan); SDL headers come from the sdl dep (3.4.x ABI
    // matches our 3.4.0 lib).
    // ponytail: no demo/widgets beyond the shim. Extend the shim per widget.
    const imgui_dep = b.dependency("imgui", .{});
    const sdl_dep = b.dependency("sdl", .{});
    lib_mod.addIncludePath(imgui_dep.path("."));
    lib_mod.addIncludePath(b.path("vendor/imgui"));
    lib_mod.addIncludePath(sdl_dep.path("include"));
    lib_mod.addIncludePath(b.dependency("vulkan_headers", .{}).path("include"));
    {
        const imgui_flags = &.{ "-std=c++17", "-DIMGUI_IMPL_VULKAN_NO_PROTOTYPES" };
        for ([_][]const u8{
            "imgui.cpp",
            "imgui_draw.cpp",
            "imgui_tables.cpp",
            "imgui_widgets.cpp",
            "backends/imgui_impl_sdl3.cpp",
            "backends/imgui_impl_vulkan.cpp",
        }) |f| {
            lib_mod.addCSourceFile(.{ .file = imgui_dep.path(f), .flags = imgui_flags });
        }
        lib_mod.addCSourceFile(.{ .file = b.path("vendor/imgui/imgui_shim.cpp"), .flags = imgui_flags });
    }

    // Jolt Physics (jolt dep, file list in vendor/jolt/sources.zig).
    // Excludes Jolt/Renderer/ (its debug renderer; hitboxes go through debug
    // geometry instead). ponytail: ~150 files is a one-time compile, cached
    // after. C++17, no exceptions/RTTI (Jolt uses neither).
    const jolt_dep = b.dependency("jolt", .{});
    lib_mod.addIncludePath(jolt_dep.path("."));
    lib_mod.addIncludePath(b.path("vendor/jolt"));
    {
        const jolt_sources = @import("vendor/jolt/sources.zig").files;
        const jolt_flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" };
        for (jolt_sources) |f| {
            lib_mod.addCSourceFile(.{
                .file = jolt_dep.path(f),
                .flags = jolt_flags,
            });
        }
        lib_mod.addCSourceFile(.{ .file = b.path("vendor/jolt/jolt_shim.cpp"), .flags = jolt_flags });
    }

    const sdl3 = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    });

    lib_mod.addImport("vulkan", vulkan.module("vulkan-zig"));
    lib_mod.addImport("sdl3", sdl3.module("sdl3"));

    // C bindings via build-system translate-c. @cImport is forbidden in project
    // code; translation also happens per-target at build time anyway.
    const jolt_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/jolt/jolt_shim.h"),
        .target = target,
        .optimize = optimize,
    });
    jolt_c.addIncludePath(jolt_dep.path("."));
    jolt_c.addIncludePath(b.path("vendor/jolt"));
    lib_mod.addImport("jolt", jolt_c.createModule());

    const cgltf_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/cgltf/cgltf.h"),
        .target = target,
        .optimize = optimize,
    });
    cgltf_c.addIncludePath(b.path("vendor/cgltf"));
    lib_mod.addImport("cgltf", cgltf_c.createModule());

    const stb_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/stb/stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    stb_c.addIncludePath(b.path("vendor/stb"));
    lib_mod.addImport("stb", stb_c.createModule());

    const imgui_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/imgui/imgui_shim.h"),
        .target = target,
        .optimize = optimize,
    });
    imgui_c.addIncludePath(imgui_dep.path("."));
    imgui_c.addIncludePath(b.path("vendor/imgui"));
    lib_mod.addImport("imgui", imgui_c.createModule());

    const mod_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
