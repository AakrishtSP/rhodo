# Rhodo Engine — Interface Documentation

Game-facing API. Import as `rhodo` (`@import("rhodo")`); game code never
imports `sdl3`, `vulkan`, or C libraries directly. No `vk.*` or `sdl.*` types
cross the engine's public signatures.

## Frame loop (canonical order)

```zig
var renderer = try rhodo.Renderer.init(allocator, io);
defer renderer.deinit();
try rhodo.Physics.init();
defer rhodo.Physics.deinit();

while (running) {
    input.beginFrame();
    while (renderer.pollEvent()) |event| {
        input.feed(event);
        switch (event) {
            .quit => running = false,
            .resized => renderer.notifyResized(),
            else => {},
        }
    }
    renderer.pollShaderChanges();          // hot-reload, no-op when clean
    const dt = ...;                        // seconds since last frame
    rhodo.Physics.step(@min(dt, 1.0 / 30.0));
    sim.sync(rhodo.transforms[0..]);

    try renderer.beginFrame();
    renderer.setCamera(cam);
    // ... drawMesh / drawSprite / drawLine / drawAabb / drawObb ...
    renderer.beginUi();
    // ... rhodo.imgui.* calls ...
    renderer.endUi();
    try renderer.endFrame();               // flushes debug lines, presents
}
```

Order constraints: `beginUi` after 3D draws puts UI on top; `endUi` must stay
inside the render pass (before `endFrame`); debug lines flush automatically at
`endFrame` (topmost). Physics `step`/`sync` run on CPU any time before draws.

## 3D rendering (`src/renderer/main.zig`)

- `Renderer.init/deinit` — window (800×600, resizable, Vulkan), device,
  swapchain, built-in pipelines (mesh, lines, sprites), descriptor pool.
- `loadShader(vert, frag) !ShaderHandle` — mesh-layout pipeline (pos+normal,
  MVP push constant, depth on, backface cull). Built-ins in `rhodo.shader`:
  `mesh_vert`, `lit_frag` (fixed directional lambert + ambient), `flat_frag`
  (unlit white). Shader 0 (`mesh_vert`+`lit_frag`) is loaded by `init`.
- `uploadMesh(mesh.Mesh) !MeshHandle` — host-visible vertex+index buffers.
  Frees the CPU `Mesh` after upload.
- `drawMesh(shader, mesh, transform: Mat4)` — one call per mesh, pipeline
  bound per call. MVP = camera `viewProj * transform`, pushed (64B).
- `setCamera(cam: Camera)` — binds once per frame; all draws fold it in.
- `Camera` (`src/camera.zig`) — `pos`, `yaw`/`pitch` (radians), `fov_y`,
  `near=0.1`, `far=100`. `forward()`, `view()`, `projection(aspect)`.
- `rhodo.transforms: [1024]Transform` — physics writes here; render with
  `Mat4.fromTransform(t)`. `Transform = { pos: Vec3, rot: Vec4(quat), scale }`.
- `loadTexture(path) !TextureHandle`, `drawSprite(tex, transform: Mat4)` —
  see 2D below.

## Debug drawing (`src/renderer/debug.zig`)

Fire-and-forget, flushed at `endFrame` (depth off, drawn last, always visible).
World space. No-op when empty.

- `drawLine(a, b, color)` — one segment (`Vec3` endpoints, RGB `Vec3`).
- `drawAabb(min, max, color)` — 12 edges of an axis-aligned box.
- `drawObb(pos, quat, half, color)` — 12 edges of the true rotated box.
- Ceiling 8192 lines; overflow silently dropped; no sorting.

## 2D sprites + textures (`src/renderer/texture.zig`)

- `loadTexture(path: [:0]u8) !TextureHandle` — stb_image (forced RGBA) into a
  sampled `R8G8B8A8_SRGB` optimal image (staging + layout transitions), linear
  clamp sampler, one combined-image-sampler descriptor set. Ceiling 32.
- `drawSprite(tex, transform: Mat4)` — shared unit quad (UV origin top-left),
  screen space (orthographic, top-left origin, pixels). Blend on, depth off.
  One draw call per sprite, no batching.
- `Mat4.orthographic(l, r, b, t, n, f)` — Vulkan clip (Y-flipped like
  `perspective`, depth 0..1). `translate`/`scale` compose sprite placement:
  `translate(x, y, 0).mul(scale(w, h, 1))` maps the quad to a `w×h` rect.

## Physics (`src/physics.zig`, Jolt v5.6 via `vendor/jolt/jolt_shim.h`)

- `Physics.init/deinit` — 2-layer world (static/dynamic), 1024 bodies,
  thread-pool job system, 10MB temp allocator.
- `addBox(pos, half, is_static) !BodyHandle` — axis-aligned box. Boxes only.
- `step(dt)` — variable dt (clamped by caller); no fixed timestep.
- `sync(transforms: []Transform)` — writes pos/quat/scale (`scale = half` so
  the −1..1 cube mesh matches). No removal, no velocity/rotation setters, no
  contacts, no other shapes.

## Input

Engine (`Renderer.Event`, no SDL in game code): `quit`, `resized`,
`key_down`/`key_up: KeyCode`, `axis_motion{axis, value}` (sticks −1..1),
`mouse_motion{dx, dy}` (relative pixels). `KeyCode` covers bound keyboard
scancodes (`w a s d f g space left_shift escape`), gamepad buttons
(`pad_south/east/west/north`, dpad, `l1 r1 start`), stick axes. One gamepad
slot (first connected wins, hot-plug).
- `setMouseCapture(bool)` — relative mode for mouse-look; `Esc` toggles.

Sandbox mapper (`sandbox/input.zig`, game-owned): `Action` enum bound to
`[]const KeyCode`; `Input{beginFrame, feed, isPressed, isJustPressed,
isJustReleased, axisValue, mouse_dx/dy}`. Per-device routing convention:
mouse + keys drive only when captured, sticks always drive.

## UI (`rhodo.imgui`, Dear ImGui 1.92 via `vendor/imgui/imgui_shim.h`)

Engine owns backend init/shutdown (`initUi`/`shutdownUi` in `init`/`deinit`),
per-frame `beginUi`/`endUi`, raw SDL event feed in `pollEvent`, and
`SetMinImageCount` on resize. Game code calls the shim directly — no wrapper:
`Begin/End`, `Text` (plain string; format in Zig), `Button`, `Checkbox`,
`SliderFloat`, `SameLine`, `Separator`, `SetNextWindowPos/Size`,
`WantCaptureMouse/Keyboard` (gate game input while interacting), `Framerate`.
Reuses shaders[0]'s render pass; backend-owned descriptor pool.

## Shaders

HLSL source in `shaders/*.hlsl`, compiled by `dxc -spirv` on every build
(`vs_6_0`/`ps_6_0`); committed `.spv` runs the app. Mesh shaders use a 64B
MVP push constant (`mul(mvp, v)`); line/sprite shaders reuse the layout.
`pollShaderChanges()` (called per frame) rebuilds any pipeline whose `.spv`
changed, keeps the old one on failure, prints once. Garbage SPV is rejected
before reaching the driver (`error.InvalidSpirv`).

## Math (`src/math.zig`)

`Vec3` (`add/sub/scale/cross/dot/normalize/rotateByQuat`), `Vec4`, `Mat4`
column-major (`identity/mul/transpose/perspective/lookAt/rotationY/
orthographic/translate/scale/fromTransform/orientedBoxAabb`).

## Mesh loading (`src/renderer/mesh.zig`)

`loadGltf(allocator, path) !Mesh` (cgltf, concatenates all primitives, ignores
node hierarchy), `cube(allocator)` (2-unit, 24 verts). `Vertex{pos, normal}`.

## Audio

Not implemented. Planned: procedural blips via SDL audio (no files).

## Ceilings (raise when a game forces it)

1024 transforms/bodies · 8 shaders · 64 meshes · 32 textures · 8192 debug
lines · 1 gamepad · boxes only · no mipmaps · no batching · variable timestep.
