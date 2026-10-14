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
    while (input.poll()) |event| {
        switch (event) {
            .quit => running = false,
            .resized => renderer.notifyResized(),
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
- `drawMesh(shader, mesh, transform: Mat4)` — unlit/custom pipelines (flat
  ground). `drawMeshTinted(mesh, color: Vec4, transform)` / `drawModel(model,
  transform)` — lit + RGBA tint via shader 0 (80B MVP+color push). `Model =
  { mesh, color }` bundles both; `texture` and skeletal/keyframe runtime join
  when a textured/animated glTF arrives (physics + procedural cover motion).
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

## 2D sprites + textures (`src/renderer/sprite.zig`, `texture.zig`)

- `loadTexture(path: [:0]u8) !TextureHandle` — stb_image (forced RGBA) into a
  sampled `R8G8B8A8_SRGB` optimal image (staging + layout transitions), linear
  clamp sampler, one combined-image-sampler descriptor set. Ceiling 32.
- `drawSprite(tex, transform: Mat4)` — shared unit quad (UV origin top-left),
  screen space (orthographic, top-left origin, pixels). Blend on, depth off.
  One draw call per sprite, no batching. Sub-rectangles (spritesheets) need a
  UV-rect push — not yet implemented, see below.
- `Mat4.orthographic(l, r, b, t, n, f)` — Vulkan clip (Y-flipped like
  `perspective`, depth 0..1). `translate`/`scale` compose sprite placement:
  `translate(x, y, 0).mul(scale(w, h, 1))` maps the quad to a `w×h` rect.

## Physics (`src/physics.zig`, Jolt v5.6 via `vendor/jolt/jolt_shim.h`)

- `Physics.init/deinit` — 2-layer world (static/dynamic), 1024 bodies,
  thread-pool job system, 10MB temp allocator.
- `addBox(pos, half, is_static) !BodyHandle` — axis-aligned box. Boxes only.
- `removeBox(handle)` — Jolt remove + destroy (tombstone; slots leak until
  restart resets all).
- `step(dt)` — variable dt (clamped by caller); no fixed timestep.
- `sync(transforms, alive)` — writes pos/quat/scale (`scale = half` so
  the −1..1 cube mesh matches), skipping dead. No velocity setters, no
  contacts, no other shapes.

## Entities (`src/entity.zig`)

Data-oriented game objects: every entity is exactly one box body + optional
visual — parallel arrays (`models[]`, `is_static[]`, `alive[]`) keyed by
stable index, no pointers, no methods on entities. Reuses `transforms[]` and
`Physics` (entity id = body/transform index; all bodies spawn through here).
- `spawn(sim, pos, half, is_static, model: ?Model) !Entity` — mesh + body
  composed in one call (the per-type constructors in game code are the
  Godot-like composition point).
- `despawn(sim, id)`, `reset()`. No reuse (see removal note above).
- Draw by iterating `0..count`, skipping dead. Non-physical entities need an
  id↔body map (add when triggers/markers arrive).

## Audio (`src/audio.zig`)

Procedural SFX, no files/mixer/music. `Audio.init()` (infallible — logs and
stays silent with no device), generated click/pop/thud blips (22050Hz S16
mono), `play(handle)`, `deinit()`. Per-entity voices arrive with the second
enemy type.

## Input (`src/input.zig`)

Engine-owned polled state. Game code owns an instance (`var input: rhodo.Input`)
and drains with `poll()` — the single SDL queue drain (feeds ImGui first,
manages the gamepad slot). Requires SDL initialized (`Renderer.init`).

- `beginFrame()` — clears edge flags + mouse delta. `poll() ?Event` — returns
  `quit`/`resized` only; keys/buttons/axes fold into state (not returned).
- Queries: `isDown`, `isJustPressed`, `isJustReleased` (per-frame edges),
  `axisValue` (sticks −1..1), `mouse_dx/dy` (relative pixels). `deinit`
  closes the gamepad.
- `KeyCode` — bound keyboard scancodes, gamepad buttons (positional
  `pad_south`…), stick axes. One gamepad slot (first wins, hot-plug).
- `Renderer.setMouseCapture(bool)` — relative mode for mouse-look (window
  property, stays on renderer).

Sandbox convention (`sandbox/input.zig`, game-owned): `Action` enum mapped to
`[]const KeyCode` with thin `isPressed/isJustPressed` queries over engine
state. Per-device routing: mouse + keys drive only when captured, sticks
always drive (gamepad is never a UI pointer).

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
