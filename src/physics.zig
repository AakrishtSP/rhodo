const std = @import("std");
const math = @import("math.zig");
const jolt = @import("jolt");

pub const BodyHandle = u32;
pub const CharacterHandle = u32;

/// How a body moves.
pub const BodyType = enum(u8) {
    /// Never moves: floor, walls. Can't be pushed.
    static = 0,
    /// Moved only by the game (`setVelocity` / moving platforms). Ignores
    /// gravity, pushes dynamic bodies, can't be pushed.
    kinematic = 1,
    /// Simulated: gravity, collisions, velocity, stacking.
    dynamic = 2,
};

/// Which shape a body was created with (debug drawing only).
pub const ShapeKind = enum(u8) { box, sphere, capsule, cylinder, plane };

/// Default collider gizmo colors, by motion type. Triggers use `trigger`.
pub const collider_colors = struct {
    pub const static = math.Vec4{ .x = 0.55, .y = 0.55, .z = 0.6, .w = 1 };
    pub const kinematic = math.Vec4{ .x = 0.25, .y = 0.6, .z = 1.0, .w = 1 };
    pub const dynamic = math.Vec4{ .x = 0.25, .y = 1.0, .z = 0.45, .w = 1 };
    pub const trigger = math.Vec4{ .x = 1.0, .y = 0.85, .z = 0.2, .w = 1 };
};

const max_characters = 8;

/// World transforms written by `sync()`, indexed by body handle. The renderer
/// reads these (`drawBody`, `drawColliders`); games use `transform(handle)`.
pub var transforms: [1024]math.Transform = undefined;

/// One collider. A body with no matching mesh is invisible until debug draw;
/// a mesh with no body is just something the game draws. They are independent.
pub const Body = struct {
    id: u32 = 0,
    kind: ShapeKind = .box,
    /// Shape bounds: written to transforms[].scale for drawing.
    scale: math.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    /// Plane bodies only (for the gizmo).
    normal: math.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    /// Gizmo color; override with `setColor`.
    color: math.Vec4 = collider_colors.static,
    alive: bool = false,
};

/// One character move result. `pos` is the capsule center.
pub const Character = struct {
    pos: math.Vec3,
    grounded: bool,
};

// Minimal Jolt wrapper: init/shutdown once, box/sphere/capsule/cylinder/plane
// bodies (static/kinematic/dynamic, optional sensors), kinematic capsule
// characters, step, and sync that writes every body into transforms[].
// Colliders and meshes are independent: a body needs no mesh, a mesh needs no
// body; `renderer.drawColliders` visualizes colliders from the synced
// transforms for debugging.
// ponytail: 1024-body ceiling matching transforms[], no contacts/events (use
// `overlaps` per trigger), no character-vs-character.
pub const Physics = struct {
    bodies: [1024]Body = @splat(.{}),
    count: u32 = 0,

    // Characters are not rigid bodies: separate slots, own positions.
    char_ids: [max_characters]u32 = undefined,
    /// half_height + radius: feet (Jolt's position) -> capsule center.
    char_offsets: [max_characters]f32 = undefined,
    char_alive: [max_characters]bool = @splat(false),
    char_count: u32 = 0,

    pub fn init() !void {
        if (!jolt.Jolt_Init()) return error.PhysicsInitFailed;
    }

    pub fn deinit() void {
        jolt.Jolt_Shutdown();
    }

    pub fn addBox(self: *Physics, pos: math.Vec3, half: math.Vec3, body_type: BodyType) !BodyHandle {
        const p = vec3f(pos);
        const h = vec3f(half);
        return self.record(jolt.Jolt_AddBox(&p, &h, @backingInt(body_type)), .box, half, body_type);
    }

    pub fn addSphere(self: *Physics, pos: math.Vec3, radius: f32, body_type: BodyType) !BodyHandle {
        const p = vec3f(pos);
        return self.record(jolt.Jolt_AddSphere(&p, radius, @backingInt(body_type)), .sphere, .{
            .x = radius,
            .y = radius,
            .z = radius,
        }, body_type);
    }

    /// Upright capsule; `half_height` is the straight section's half height.
    pub fn addCapsule(self: *Physics, pos: math.Vec3, radius: f32, half_height: f32, body_type: BodyType) !BodyHandle {
        const p = vec3f(pos);
        return self.record(jolt.Jolt_AddCapsule(&p, radius, half_height, @backingInt(body_type)), .capsule, .{
            .x = radius,
            .y = half_height + radius,
            .z = radius,
        }, body_type);
    }

    /// Upright cylinder; `half_height` is the half height (radius excluded).
    pub fn addCylinder(self: *Physics, pos: math.Vec3, radius: f32, half_height: f32, body_type: BodyType) !BodyHandle {
        const p = vec3f(pos);
        return self.record(jolt.Jolt_AddCylinder(&p, radius, half_height, @backingInt(body_type)), .cylinder, .{
            .x = radius,
            .y = half_height,
            .z = radius,
        }, body_type);
    }

    /// Infinite plane through `pos` with `normal`. Static only (Jolt can't move
    /// a plane body sensibly); its transform scale is a unit marker — draw your
    /// own floor quad if the plane isn't at the origin.
    pub fn addPlane(self: *Physics, pos: math.Vec3, normal: math.Vec3, body_type: BodyType) !BodyHandle {
        std.debug.assert(body_type == .static);
        const p = vec3f(pos);
        const n = vec3f(normal);
        const handle = try self.record(jolt.Jolt_AddPlane(&p, &n, @backingInt(body_type)), .plane, .{
            .x = 1,
            .y = 1,
            .z = 1,
        }, body_type);
        self.bodies[handle].normal = normal;
        return handle;
    }

    /// Pass-through collider: no contact response, but `overlaps` reports what
    /// is inside it. Recolors a new trigger yellow; call `setColor` after if you
    /// want hitbox/hurtbox colors.
    pub fn setTrigger(self: *Physics, handle: BodyHandle, trigger: bool) void {
        if (!self.bodies[handle].alive) return;
        jolt.Jolt_SetSensor(self.bodies[handle].id, trigger);
        if (trigger) self.bodies[handle].color = collider_colors.trigger;
    }

    /// Gizmo color (debug draw only, never affects the simulation).
    pub fn setColor(self: *Physics, handle: BodyHandle, color: math.Vec4) void {
        if (!self.bodies[handle].alive) return;
        self.bodies[handle].color = color;
    }

    /// Bodies whose shape intersects `handle` (self excluded), written into
    /// `out`. Solid bodies show up too — filter by vocabulary (the game knows
    /// which handles are players/enemies/props).
    pub fn overlaps(self: *Physics, handle: BodyHandle, out: []BodyHandle) []BodyHandle {
        if (!self.bodies[handle].alive) return out[0..0];
        var ids: [64]u32 = undefined;
        const max: c_int = @intCast(@min(out.len, ids.len));
        const n: usize = @intCast(jolt.Jolt_Overlaps(self.bodies[handle].id, &ids, max));
        var count: usize = 0;
        for (ids[0..n]) |id| {
            // ponytail: linear id->handle scan; a map if you have 1000s of bodies.
            for (0..self.count) |i| {
                if (self.bodies[i].alive and self.bodies[i].id == id) {
                    out[count] = @intCast(i);
                    count += 1;
                    break;
                }
            }
        }
        return out[0..count];
    }

    /// Drive a kinematic (moving platform) or dynamic body. Static ignores it.
    pub fn setVelocity(self: *Physics, handle: BodyHandle, velocity: math.Vec3) void {
        if (!self.bodies[handle].alive) return;
        const v = [_]f32{ velocity.x, velocity.y, velocity.z };
        jolt.Jolt_SetBodyVelocity(self.bodies[handle].id, &v);
    }

    pub fn step(dt: f32) void {
        jolt.Jolt_Step(dt);
    }

    pub fn removeBody(self: *Physics, handle: BodyHandle) void {
        if (!self.bodies[handle].alive) return;
        jolt.Jolt_RemoveBody(self.bodies[handle].id);
        self.bodies[handle].id = std.math.maxInt(u32);
        self.bodies[handle].alive = false;
    }

    fn record(self: *Physics, id: u32, kind: ShapeKind, scale: math.Vec3, body_type: BodyType) !BodyHandle {
        if (id == std.math.maxInt(u32)) return error.BodyCreateFailed;
        if (self.count >= 1024) {
            jolt.Jolt_RemoveBody(id); // don't leak the body we just created
            return error.TooManyBodies;
        }
        const handle = self.count;
        self.bodies[handle] = .{
            .id = id,
            .kind = kind,
            .scale = scale,
            .color = defaultColor(body_type),
            .alive = true,
        };
        self.count += 1;
        return handle;
    }

    /// Refresh the world transforms for every live body. Call once after
    /// `step`, before drawing.
    pub fn sync(self: *Physics) void {
        for (0..self.count) |i| {
            const b = self.bodies[i];
            if (!b.alive) continue;
            var p: [3]f32 = undefined;
            var q: [4]f32 = undefined;
            jolt.Jolt_GetTransform(b.id, &p, &q);
            transforms[i] = .{
                .pos = .{ .x = p[0], .y = p[1], .z = p[2] },
                .rot = .{ .x = q[0], .y = q[1], .z = q[2], .w = q[3] },
                .scale = b.scale,
            };
        }
    }

    /// Last synced transform (pos/quat + shape bounds as scale).
    pub fn transform(self: *const Physics, handle: BodyHandle) math.Transform {
        std.debug.assert(self.bodies[handle].alive);
        return transforms[handle];
    }

    // --- characters (KinematicVirtual capsule) -----------------------------

    /// `center` is the capsule center (same convention as body positions).
    pub fn addCharacter(self: *Physics, center: math.Vec3, radius: f32, half_height: f32) !CharacterHandle {
        if (self.char_count >= max_characters) return error.TooManyCharacters;
        const offset = half_height + radius;
        const feet = [_]f32{ center.x, center.y - offset, center.z };
        const id = jolt.Jolt_AddCharacter(&feet, radius, half_height);
        if (id == std.math.maxInt(u32)) return error.CharacterCreateFailed;
        const handle = self.char_count;
        self.char_ids[handle] = id;
        self.char_offsets[handle] = offset;
        self.char_alive[handle] = true;
        self.char_count += 1;
        return handle;
    }

    /// Move once. `velocity` is the full desired velocity *including* gravity —
    /// the engine adds none, so jump feel belongs to the game. Collides and
    /// slides, walks steps, stops on slopes, reports grounded.
    pub fn moveCharacter(self: *Physics, handle: CharacterHandle, velocity: math.Vec3, dt: f32) Character {
        std.debug.assert(self.char_alive[handle]);
        const v = [_]f32{ velocity.x, velocity.y, velocity.z };
        var p: [3]f32 = undefined;
        var grounded = false;
        jolt.Jolt_CharacterMove(self.char_ids[handle], &v, dt, &p, &grounded);
        return .{
            .pos = .{ .x = p[0], .y = p[1] + self.char_offsets[handle], .z = p[2] },
            .grounded = grounded,
        };
    }

    pub fn removeCharacter(self: *Physics, handle: CharacterHandle) void {
        if (!self.char_alive[handle]) return;
        jolt.Jolt_RemoveCharacter(self.char_ids[handle]);
        self.char_alive[handle] = false;
    }
};

fn vec3f(v: math.Vec3) [3]f32 {
    return .{ v.x, v.y, v.z };
}

fn defaultColor(body_type: BodyType) math.Vec4 {
    return switch (body_type) {
        .static => collider_colors.static,
        .kinematic => collider_colors.kinematic,
        .dynamic => collider_colors.dynamic,
    };
}

// Headless end-to-end: static floor + falling box lands at y=1, removal skips.
test "box falls, rests, and removes cleanly" {
    try Physics.init();
    defer Physics.deinit();
    var sim: Physics = .{};
    _ = try sim.addBox(
        .{ .x = 0, .y = -1, .z = 0 },
        .{ .x = 10, .y = 1, .z = 10 },
        .static,
    );
    const box = try sim.addBox(
        .{ .x = 0, .y = 5, .z = 0 },
        .{ .x = 1, .y = 1, .z = 1 },
        .dynamic,
    );
    for (0..120) |_| Physics.step(1.0 / 60.0);
    sim.sync();
    try std.testing.expectApproxEqAbs(@as(f32, 1), sim.transform(box).pos.y, 0.1);

    sim.removeBody(box);
    sim.sync();
    try std.testing.expect(sim.bodies[box].alive == false);
}

test "shapes: plane floor, sphere rests, capsule/cylinder bounds" {
    try Physics.init();
    defer Physics.deinit();
    var sim: Physics = .{};
    _ = try sim.addPlane(.{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 }, .static);
    const sphere = try sim.addSphere(.{ .x = 0, .y = 5, .z = 0 }, 0.5, .dynamic);
    const capsule = try sim.addCapsule(.{ .x = 3, .y = 5, .z = 0 }, 0.3, 0.5, .dynamic);
    const cylinder = try sim.addCylinder(.{ .x = 6, .y = 5, .z = 0 }, 0.4, 0.6, .dynamic);

    for (0..180) |_| Physics.step(1.0 / 60.0);
    sim.sync();

    // transforms[].scale carries the shape bounds for drawing
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sim.transform(sphere).scale.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), sim.transform(capsule).scale.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), sim.transform(cylinder).scale.y, 1e-6);
    // sphere rests on the plane at its radius
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sim.transform(sphere).pos.y, 0.05);
}

test "kinematic body holds position, dynamic falls" {
    try Physics.init();
    defer Physics.deinit();
    var sim: Physics = .{};
    const kin = try sim.addBox(.{ .x = 0, .y = 5, .z = 0 }, .{ .x = 1, .y = 1, .z = 1 }, .kinematic);
    const dyn = try sim.addBox(.{ .x = 5, .y = 5, .z = 0 }, .{ .x = 1, .y = 1, .z = 1 }, .dynamic);
    for (0..60) |_| Physics.step(1.0 / 60.0);
    sim.sync();
    try std.testing.expectApproxEqAbs(@as(f32, 5), sim.transform(kin).pos.y, 1e-3);
    try std.testing.expect(sim.transform(dyn).pos.y < 5);
}

test "character falls, lands and reports grounded" {
    try Physics.init();
    defer Physics.deinit();
    var sim: Physics = .{};
    _ = try sim.addBox(.{ .x = 0, .y = -1, .z = 0 }, .{ .x = 10, .y = 1, .z = 10 }, .static);

    const radius: f32 = 0.3;
    const half_height: f32 = 0.5;
    const char = try sim.addCharacter(.{ .x = 0, .y = 2, .z = 0 }, radius, half_height);

    const dt: f32 = 1.0 / 60.0;
    var vy: f32 = 0;
    var landed = false;
    var state: Character = undefined;
    for (0..180) |_| {
        vy -= 9.81 * dt; // game-owned gravity
        state = sim.moveCharacter(char, .{ .x = 0, .y = vy, .z = 0 }, dt);
        if (state.grounded) {
            vy = 0;
            landed = true;
        }
    }

    try std.testing.expect(landed);
    // floor top is y=0, so the capsule center rests at half_height + radius.
    try std.testing.expectApproxEqAbs(half_height + radius, state.pos.y, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state.pos.x, 0.05);
}

test "trigger reports overlaps but lets bodies pass" {
    try Physics.init();
    defer Physics.deinit();
    var sim: Physics = .{};
    _ = try sim.addBox(.{ .x = 0, .y = -1, .z = 0 }, .{ .x = 10, .y = 1, .z = 10 }, .static);
    const trigger = try sim.addBox(.{ .x = 0, .y = 3, .z = 0 }, .{ .x = 2, .y = 1, .z = 2 }, .static);
    sim.setTrigger(trigger, true);
    const ball = try sim.addSphere(.{ .x = 0, .y = 8, .z = 0 }, 0.5, .dynamic);

    var hits: [8]BodyHandle = undefined;
    var saw_ball = false;
    for (0..120) |_| {
        Physics.step(1.0 / 60.0);
        for (sim.overlaps(trigger, &hits)) |h| {
            if (h == ball) saw_ball = true;
        }
    }
    try std.testing.expect(saw_ball);

    // no contact response: the ball keeps falling to the floor (top y=0)
    sim.sync();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sim.transform(ball).pos.y, 0.05);
    try std.testing.expectEqual(collider_colors.trigger, sim.bodies[trigger].color);
}
