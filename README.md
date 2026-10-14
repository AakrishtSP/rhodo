# Rhodo Engine

A Vulkan-based game engine written in Zig. FOSS library — games using it live
in separate (private) repos and depend on this via the Zig package manager.

Interface docs: `API.md`. Default shaders: `shaders/` (games compile and own
their copies).

## Dependencies

Install the following packages with pacman:

```bash
sudo pacman -S zig vulkan-devel vulkan-validation-layers directx-shader-compiler
```

- **zig** — compiler and build system (0.16.0+)
- **vulkan-devel** — Vulkan headers and loader
- **vulkan-validation-layers** — validation layers for debug builds
- **directx-shader-compiler** — HLSL to SPIR-V shader compilation (games)

SDL3 and vulkan-zig are fetched automatically by the build system.

## Building and Testing

```bash
git clone https://github.com/AakrishtSP/rhodo
# or
# git clone git@github.com:AakrishtSP/rhodo.git
# if using ssh
cd rhodo
zig build test
```

## Using it in a game

```zig
// build.zig.zon
.dependencies = .{
    .rhodo = .{
        .url = "git+https://github.com/AakrishtSP/rhodo#<commit>",
        .hash = "...", // from `zig fetch`
    },
},
```

```zig
// build.zig
const rhodo = b.dependency("rhodo", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("rhodo", rhodo.module("rhodo"));
```

## Notes

- Validation layers are enabled automatically in debug builds
- Jolt Physics, Dear ImGui, and SDL headers come from versioned `zig fetch`
  dependencies (see `build.zig.zon`); only single-header libs (cgltf,
  stb_image) plus our C shims live in `vendor/`.
