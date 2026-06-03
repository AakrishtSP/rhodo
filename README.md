# Rhodo Engine

A Vulkan-based game engine written in Zig.

## Dependencies

Install the following packages with pacman:

```bash
sudo pacman -S zig vulkan-devel vulkan-validation-layers directx-shader-compiler
```

- **zig** — compiler and build system (0.16.0+)
- **vulkan-devel** — Vulkan headers and loader
- **vulkan-validation-layers** — validation layers for debug builds
- **directx-shader-compiler** — HLSL to SPIR-V shader compilation

SDL3 and vulkan-zig are fetched automatically by the build system.

## Building and Running

```bash
git clone https://github.com/AakrishtSP/rhodo
# or
# git clone git@github.com:AakrishtSP/rhodo.git
# if using ssh
cd rhodo
zig build run # For debug builds
# or
zig build run -Doptimize=ReleaseFast # For Release builds
```

## Controls

- `Escape` — quit

## Notes

- Validation layers are enabled automatically in debug builds (`zig build run`)
- To build without validation: `zig build run -Doptimize=ReleaseFast`
- Shaders are recompiled automatically on each build via `dxc`
