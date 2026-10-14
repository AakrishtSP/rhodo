const std = @import("std");
const math = @import("math.zig");
const C = @cImport({
    @cInclude("jolt_shim.h");
});

pub const BodyHandle = u32;

// Minimal Jolt wrapper: init/shutdown once, static + dynamic box bodies, step,
// and sync that writes every body into transforms[] (pos + quat, scale set to
// the half extent so the -1..1 unit-cube mesh matches the Jolt box).
// ponytail: boxes only, 1024-body ceiling matching transforms[]. More shapes,
// removal, and collision callbacks when a game needs them.
pub const Physics = struct {
    ids: [1024]u32 = undefined,
    halfs: [1024]math.Vec3 = undefined,
    alive: [1024]bool = .{false} ** 1024,
    count: u32 = 0,

    pub fn init() !void {
        if (!C.Jolt_Init()) return error.PhysicsInitFailed;
    }

    pub fn deinit() void {
        C.Jolt_Shutdown();
    }

    pub fn addBox(self: *Physics, pos: math.Vec3, half: math.Vec3, is_static: bool) !BodyHandle {
        if (self.count >= 1024) return error.TooManyBodies;
        const p = [_]f32{ pos.x, pos.y, pos.z };
        const h = [_]f32{ half.x, half.y, half.z };
        const id = C.Jolt_AddBox(&p, &h, is_static);
        if (id == 0xFFFFFFFF) return error.BodyCreateFailed;
        const handle = self.count;
        self.ids[handle] = id;
        self.halfs[handle] = half;
        self.alive[handle] = true;
        self.count += 1;
        return handle;
    }

    pub fn step(dt: f32) void {
        C.Jolt_Step(dt);
    }

    pub fn removeBox(self: *Physics, handle: BodyHandle) void {
        if (!self.alive[handle]) return;
        C.Jolt_RemoveBox(self.ids[handle]);
        self.ids[handle] = 0xFFFFFFFF;
        self.alive[handle] = false;
    }

    pub fn sync(self: *Physics, transforms: []math.Transform) void {
        for (0..self.count) |i| {
            if (!self.alive[i]) continue;
            var p: [3]f32 = undefined;
            var q: [4]f32 = undefined;
            C.Jolt_GetTransform(self.ids[i], &p, &q);
            transforms[i] = .{
                .pos = .{ .x = p[0], .y = p[1], .z = p[2] },
                .rot = .{ .x = q[0], .y = q[1], .z = q[2], .w = q[3] },
                .scale = self.halfs[i],
            };
        }
    }
};

// Headless end-to-end: static floor + falling box lands at y=1, removal skips.
test "box falls, rests, and removes cleanly" {
    try Physics.init();
    defer Physics.deinit();
    var sim: Physics = .{};
    _ = try sim.addBox(
        .{ .x = 0, .y = -1, .z = 0 },
        .{ .x = 10, .y = 1, .z = 10 },
        true,
    );
    const box = try sim.addBox(
        .{ .x = 0, .y = 5, .z = 0 },
        .{ .x = 1, .y = 1, .z = 1 },
        false,
    );
    var transforms: [4]math.Transform = undefined;
    var i: u32 = 0;
    while (i < 300) : (i += 1) {
        Physics.step(1.0 / 60.0);
        sim.sync(transforms[0..]);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1), transforms[box].pos.y, 0.05);
    sim.removeBox(box);
    Physics.step(1.0 / 60.0);
    sim.sync(transforms[0..]); // skips dead, no crash
}
