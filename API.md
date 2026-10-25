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
    sim.sync();

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
- `uploadModel(mesh.Mesh, color: Vec4) !Model` — upload + color in one call
  (the usual path for a visual).
- `drawMesh(shader, mesh, transform: Mat4)` — unlit/custom pipelines (flat
  ground). `drawMeshTinted(mesh, color: Vec4, transform)` / `drawModel(model,
  transform)` — lit + RGBA tint via shader 0 (96B MVP+color+light push).
  `drawBody(sim, handle, model)` uses that body's last synced transform.
  `Model = { mesh, color }` bundles both; `texture` and skeletal/keyframe
  runtime join when a textured/animated glTF arrives (physics + procedural
  cover motion).
- `setCamera(cam: Camera)` — binds once per frame; all draws fold it in.
- `setLight(dir: Vec3, ambient: f32)` — scene sun bound like the camera
  (direction normalized, ambient clamped 0..1); folded into lit draws.
  One directional only; point lights + fog arrive with atmosphere work.
- `Camera` (`src/camera.zig`) — `pos`, `yaw`/`pitch` (radians), `pitch_min`/
  `pitch_max` (clamped by `addLook`), `fov_y`, `near=0.1`, `far=100`.
  `forward()`, `right()`, `view()`, `projection(aspect)`,
  `addLook(input, dt, .{})` (mouse while the keyboard device is live + right
  stick), `orbit(target, distance)` (places the camera behind its look
  direction, aimed at target), `orbitOffset(target, distance, right, up)`
  (over-the-shoulder boom; orientation stays yaw/pitch). Clamp the boom with a
  glass-only `Physics.raycast` from the target to the desired position.
- `screenSize() Vec2` — current swapchain size in pixels.
- `worldToScreen(pos) ?Vec2` — world point to top-left pixel coordinates; null
  behind the camera or outside depth. Use it to place ImGui cell labels.
- `sim.transform(handle)` — last synced `Transform = { pos, rot(quat), scale }`
  (scale = shape bounds).
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

- `Physics.init/deinit` — 1024 bodies, thread-pool job system, 10MB temp
  allocator. Jolt still uses two broadphase motion layers (non-moving/moving);
  per-body `layers`/`mask` add fine-grained filtering on top.
- `addBox(pos, half, body_type)`, `addSphere(pos, radius)`,
  `addCapsule(pos, radius, half_height)`, `addCylinder(pos, radius,
  half_height)` — all take `body_type` last. Capsules/cylinders are upright
  (Y); `half_height` is the straight section's half height, radius excluded.
- `addPlane(pos, normal, .static)` — infinite plane through `pos`; the only
  useful body type (a moving plane makes no sense). Its transform scale is a
  unit marker, so draw your own floor quad.
- `BodyType` = `.static` (never moves), `.kinematic` (moved by the game,
  ignores gravity, pushes dynamic bodies), `.dynamic` (simulated). Kinematic and
  static share the non-moving layer, so a platform pushes but is never pushed.
- `setVelocity(handle, vel)` — drive a kinematic platform or dynamic body;
  static ignores it.
- `removeBody(handle)` — Jolt remove + destroy (tombstone; slots leak until
  restart resets all).
- `setTrigger(handle, true)` — make a **sensor**: no contact response (bodies
  pass through), still found by `overlaps`. Newly-set triggers recolor yellow
  (see `setColor`).
- `overlaps(handle, out: []BodyHandle) []BodyHandle` — bodies whose shape
  intersects this one (self excluded). This is how triggers detect what is
  inside them; solid bodies are included, so the game filters by its own
  vocabulary. Cheap shape query, call once per trigger per frame after `step`.
  `overlapsMasked(handle, out, layers)` does the same but only bodies whose
  `layers` intersect `layers`.
- `overlaps` currently sees only rigid bodies, not `CharacterVirtual`s.
- `setLayers(handle, layers: u32, mask: u32)` — layer membership + collision
  mask. `layers` is the set of layers the body belongs to; `mask` is the set it
  collides with. Bodies collide only when both agree:
  `(a.layers & b.mask) != 0 and (b.layers & a.mask) != 0`. Defaults are layer
  bit 0 and all masks (`rhodo.default_layers`, `rhodo.all_layers`). Queries use
  `layers` only, so `mask` never hides a body from a ray.
- `raycast(origin, dir, max_distance, layers) ?Physics.RayHit` — closest body
  hit. `RayHit = { body, point, normal, distance }`; `dir` need not be
  normalized. `layers` selects bodies by their `layers` bits, **not** their
  collision mask. Aim with your glass bit; for the laser start at the inner
  cell face plus epsilon so it doesn't hit its own pane. `layers = 0` misses.
- `raycastCharacters(origin, dir, max_distance, layers) ?Physics.CharacterHit` —
  ray/capsule test against `CharacterVirtual`s (they are not in Jolt's
  broadphase). Same layer semantics; `CharacterHit = { character, point,
  normal, distance }`. Pick the nearer of a body hit and a character hit for
  line-of-fire checks.
- `characterOverlaps(character, out: []BodyHandle, layers) []BodyHandle` —
  bodies intersecting a character's capsule. Use this (not `overlaps`) for
  hurtboxes/trigger volumes around player or enemies.
- `setColor(handle, Vec4)` — collider **gizmo** color only (never the sim).
  Defaults: static grey, kinematic blue, dynamic green, trigger yellow
  (`rhodo.collider_colors`). Hitbox/hurtbox = just colors you pick, e.g. red
  for damage dealers, green for damage takers.
- `step(dt)` — variable dt (clamped by caller); no fixed timestep.
- `sync(transforms)` — writes pos/quat/scale, skipping removed bodies. `scale`
  is the shape's bounds (`box` half extent, capsule `(r, h+r, r)`, cylinder
  `(r, h, r)`, sphere `(r,r,r)`), so a unit mesh draws the shape without
  per-shape branching. No contacts/events, no impulses, no hull/mesh shapes.
- `renderer.drawColliders(&sim)` — wireframe every live collider with its
  color, using the transforms from the last `sync()`. Colliders are **not** rendered
  by default: a body with no mesh is invisible until this is on. A mesh with
  no body is simply a draw call with your own `Mat4`. The two are independent.
  `sim.bodies[i]` is public (`id, kind, scale, normal, color, layers, mask,
  alive`).
  Characters aren't bodies: draw theirs with `renderer.drawCapsule(pos, axis,
  radius, half_height, color)`.

### Characters (`CharacterVirtual` capsule)

```zig
const ch = try sim.addCharacter(center, radius, half_height); // center = capsule middle
var vy: f32 = 0;
vy -= 9.81 * dt;                                   // game-owned gravity
const s = sim.moveCharacter(ch, .{ .x = vx, .y = vy, .z = vz }, dt);
if (s.grounded) vy = 0;                            // s.pos = new center
sim.removeCharacter(ch);
```

- Not a rigid body: no mass, never falls on its own. The game owns gravity,
  jump, acceleration and air control; the engine owns collide-and-slide,
  stair stepping (0.4), slope limit (50°), stick-to-floor (0.5) and the
  `grounded` flag.
- The velocity passed to `moveCharacter` must already include gravity — the
  engine adds none (no double gravity, no fighting the game's jump feel).
- Capsule center is the input/output position (same convention as bodies);
  the shim converts to Jolt's feet-at-origin shape internally.
- Up to 8 characters per `Physics`; no character-vs-character collision.
- `setCharacterLayers(handle, layers, mask)` sets query bits and the character's
  collision layer/mask (same two-way rule as bodies). Defaults are layer bit 0
  and all masks; a character only collides with bodies that accept each other.

Game objects are per-type structs over these registries (e.g. a `Prop`
`{body, model: ?Model}` with a `spawn` constructor), not engine entities —
behavior state (HP, cooldowns) lives with the struct, shared aspects
(transforms, meshes, bodies) stay flat and index-addressed. `model = null` is
a collider-only object; a mesh drawn without a prop is render-only.

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
- Raw queries: `isPressed`, `isJustPressed` (first frame only — OS auto-repeat
  never re-fires it), `isJustReleased`, `isRepeated` (auto-repeat frames while
  held), `axisValue` (raw −1..1, triggers 0..1), `axisStrength` (deadzoned,
  rescaled, signed), `mouse_dx/dy` (relative pixels). `deinit` closes the pad.
- `Key` / `PadButton` / `PadAxis` — the full SDL sets re-exported, so every key,
  pad button and axis is available with no per-key engine work. Pad names are
  positional (`pad_south` = PS cross / Xbox A). One pad slot (first wins,
  hot-plug); unplug clears its state.
- Focus loss clears all held keys/buttons/axes — no stuck movement after
  alt-tab (SDL never delivers the matching releases).

### Actions (`setMap`, Godot-style InputMap)

Map readable names to physical controls once, then query by name:

```zig
const actions = .{
    .move_forward = &[_]rhodo.Binding{
        .{ .key = .w },
        .{ .pad_button = .dpad_up },
        .{ .pad_axis = .{ .axis = .left_y, .dir = -1 } }, // stick read as a direction
    },
};
input.setMap(actions);   // comptime table: field names are the action names
```

`setMap` takes a comptime struct keyed by action name and flattens it at compile
time — no strings and no runtime table to own. `.move_forward` in the map and
`.move_forward` at the call site are the same name.

- `isActionPressed`, `isActionJustPressed`, `isActionJustReleased`,
  `isActionRepeated`, `actionStrength` (digital bindings read 1.0; sticks carry
  magnitude after the deadzone). Take the action as a string or an enum /
  enum literal — `.move_forward` and `"move_forward"` are the same lookup, so
  call sites read like Godot's `is_action_pressed` without a constant table.
- `Binding` = `.key`, `.pad_button`, or `.pad_axis{ axis, dir }` (`dir` -1 for
  up/left, 1 for down/right). `input.deadzone` is the tuning knob (default 0.25).
- `input.devices.keyboard` / `.pad` gate *action* queries only: set
  `.keyboard = captured and !ui_busy` so keys don't drive the world behind a UI,
  while the pad (never a UI pointer) keeps working. Raw queries ignore these.
- Unmapped action names assert in debug builds (typo guard).
- `Renderer.setMouseCapture(bool)` — relative mode for mouse-look (window
  property, stays on renderer).

## UI (`rhodo.imgui`, Dear ImGui 1.92 via `vendor/imgui/imgui_shim.h`)

Engine owns backend init/shutdown (`initUi`/`shutdownUi` in `init`/`deinit`),
per-frame `beginUi`/`endUi`, raw SDL event feed in `pollEvent`, and
`SetMinImageCount` on resize. Game code calls the shim directly — no wrapper:
`Begin/End`, `Text` (plain string; format in Zig), `Button`, `Checkbox`,
`SliderFloat`, `SameLine`, `Separator`, `SetNextWindowPos/Size`,
`WantCaptureMouse/Keyboard` (gate game input while interacting), `Framerate`.
`TextAt(x, y, color, str)` and `Line2D(x0, y0, x1, y1, color, thickness)` draw
on the foreground draw list (screen pixels, over windows); `color` is ImGui's
packed `0xAABBGGRR` (low byte red). Reuses shaders[0]'s render pass;
backend-owned descriptor pool.

## Shaders

HLSL source in `shaders/*.hlsl`, compiled by `dxc -spirv` on every build
(`vs_6_0`/`ps_6_0`); committed `.spv` runs the app. Mesh shaders use a 64B
MVP push constant (`mul(mvp, v)`); line/sprite shaders reuse the layout.
`pollShaderChanges()` (called per frame) rebuilds any pipeline whose `.spv`
changed, keeps the old one on failure, prints once. Garbage SPV is rejected
before reaching the driver (`error.InvalidSpirv`).

## Math (`src/math.zig`)

`Vec2`, `Vec3` (`add/sub/scale/cross/dot/normalize/rotateByQuat`), `Vec4`, `Mat4`
column-major (`identity/mul/transpose/perspective/lookAt/rotationY/
orthographic/translate/scale/fromTransform/orientedBoxAabb`). `Transform` also
has `offset(local)` (position + rotation, ignores scale), `point(local)` (full
T*R*S) and `direction(local)` (rotation only) for local-to-world conversion.
Use `offset` for hitbox/muzzle/weak-spot offsets from `Physics.transform`,
whose scale is shape bounds rather than an entity scale — keep offsets local
to the entity and convert at the boundary.

## Mesh loading (`src/renderer/mesh.zig`)

`loadGltf(allocator, path) !Mesh` (cgltf, concatenates all primitives, ignores
node hierarchy), `Vertex{pos, normal}`.

Procedural primitives, matching the collider shapes — no assets needed:

- `cube(allocator)` — unit, `[-1,1]` on every axis.
- `sphere(allocator)` — radius 1.
- `cylinder(allocator)` — radius 1, half height 1.
- `quad(allocator)` — `[-1,1]` in XZ at `y=0`, normal +Y (ground/plane).
- `capsule(allocator, radius, half_height)` — **sized**, not unit: a unit
  capsule cannot be non-uniformly scaled without distorting its caps. Build it
  at the body size and draw with `Mat4.translate`/rotation, scale 1.

Mesh vs collider is the game's choice: unit mesh + `Mat4.fromTransform(transforms[i])`
draws a body exactly (the sync's scale is the shape bounds); anything else is
just a mesh drawn at a transform of your own.

## Audio

Not implemented. Planned: procedural blips via SDL audio (no files).

## Ceilings (raise when a game forces it)

1024 transforms/bodies · 8 shaders · 64 meshes · 32 textures · 8192 debug
lines · 1 gamepad · boxes only · no mipmaps · no batching · variable timestep.
