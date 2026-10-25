const std = @import("std");
const math = @import("math.zig");
const Input = @import("input.zig").Input;

// Engine-owned camera. The sandbox drives pos/yaw/pitch from input; the renderer
// derives view/projection from it and binds it once per frame (renderer.setCamera)
// instead of threading it through every draw call.
pub const Camera = struct {
    pos: math.Vec3 = .{ .x = 0, .y = 0, .z = 4 },
    yaw: f32 = 0, // radians around +Y
    pitch: f32 = 0, // radians around camera right; positive looks up
    /// Look pitch clamp, radians. Orbit cameras often want an asymmetric range
    /// (e.g. -1.2..0.5) so they never dive under the floor.
    pitch_min: f32 = -1.5,
    pitch_max: f32 = 1.5,
    fov_y: f32 = std.math.pi / 4.0,
    near: f32 = 0.1,
    far: f32 = 100,

    // Unit direction the camera looks along. yaw=0, pitch=0 => -Z.
    pub fn forward(self: Camera) math.Vec3 {
        const cp = @cos(self.pitch);
        return .{
            .x = cp * @sin(self.yaw),
            .y = @sin(self.pitch),
            .z = -cp * @cos(self.yaw),
        };
    }

    /// Ground-plane forward (yaw only), for camera-relative WASD.
    pub fn forwardFlat(self: Camera) math.Vec3 {
        return .{ .x = @sin(self.yaw), .y = 0, .z = -@cos(self.yaw) };
    }

    /// World-space right (yaw only, so shoulder offsets do not tilt with pitch).
    pub fn right(self: Camera) math.Vec3 {
        return .{ .x = @cos(self.yaw), .y = 0, .z = @sin(self.yaw) };
    }

    /// Camera-local up (tilted with pitch).
    pub fn up(self: Camera) math.Vec3 {
        return self.right().cross(self.forward()).normalize();
    }

    /// Sensitivities for `addLook`: mouse radians/pixel, stick radians/second.
    pub const Look = struct {
        mouse: f32 = 0.0025,
        stick: f32 = 2.0,
    };

    /// Mouse look (only while `input.devices.keyboard`, so the UI/cursor wins)
    /// plus right-stick look; pitch is clamped to `pitch_min..pitch_max`.
    pub fn addLook(self: *Camera, input: *const Input, dt: f32, look: Look) void {
        if (input.devices.keyboard) {
            self.yaw += input.mouse_dx * look.mouse;
            self.pitch -= input.mouse_dy * look.mouse;
        }
        self.yaw += input.axisStrength(.right_x) * look.stick * dt;
        self.pitch -= input.axisStrength(.right_y) * look.stick * dt;
        self.pitch = std.math.clamp(self.pitch, self.pitch_min, self.pitch_max);
    }

    /// Place the camera `distance` behind its own look direction, aimed at
    /// `target`. Call after changing yaw/pitch (and again after the target moves).
    pub fn orbit(self: *Camera, target: math.Vec3, distance: f32) void {
        self.pos = target.sub(self.forward().scale(distance));
    }

    /// Over-the-shoulder boom: behind `target`, plus right/up offsets. The
    /// orientation stays yaw/pitch, so the reticle looks parallel through the
    /// shoulder rather than re-aiming at the target. Clamp `distance` yourself
    /// with a glass-only `Physics.raycast` from target to the desired position.
    pub fn orbitOffset(self: *Camera, target: math.Vec3, distance: f32, right_offset: f32, up_offset: f32) void {
        self.pos = target
            .sub(self.forward().scale(distance))
            .add(self.right().scale(right_offset))
            .add(.{ .x = 0, .y = up_offset, .z = 0 });
    }

    pub fn view(self: Camera) math.Mat4 {
        const f = self.forward();
        const center = math.Vec3{
            .x = self.pos.x + f.x,
            .y = self.pos.y + f.y,
            .z = self.pos.z + f.z,
        };
        return math.Mat4.lookAt(self.pos, center, .{ .x = 0, .y = 1, .z = 0 });
    }

    pub fn projection(self: Camera, aspect: f32) math.Mat4 {
        return math.Mat4.perspective(self.fov_y, aspect, self.near, self.far);
    }
};

test "default camera looks down -Z from +Z" {
    const cam: Camera = .{};
    const got = cam.view();
    const want = math.Mat4.lookAt(
        .{ .x = 0, .y = 0, .z = 4 },
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 1, .z = 0 },
    );
    for (got.m, want.m) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);
}

test "orbit keeps the target in front at the requested distance" {
    var cam: Camera = .{ .yaw = 0.4, .pitch = -0.3 };
    const target = math.Vec3{ .x = 1, .y = 2, .z = 3 };
    cam.orbit(target, 5);
    const d = target.sub(cam.pos);
    try std.testing.expectApproxEqAbs(@as(f32, 5), @sqrt(d.dot(d)), 1e-5);
    try std.testing.expectApproxEqAbs(cam.forward().x, d.normalize().x, 1e-5);
}

test "camera basis: flat forward, right, and pitched up" {
    const level: Camera = .{ .yaw = std.math.pi / 2.0 };
    try std.testing.expectApproxEqAbs(@as(f32, 1), level.forwardFlat().x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), level.forwardFlat().y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), level.right().x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), level.right().z, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), level.up().y, 1e-5);

    const tilted: Camera = .{ .pitch = 0.4 };
    const u = tilted.up();
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 0.4)), u.y, 1e-5);
    try std.testing.expectApproxEqAbs(@sin(@as(f32, 0.4)), u.z, 1e-5);
}

test "orbitOffset adds shoulder and height without changing aim" {
    var cam: Camera = .{};
    const target = math.Vec3{ .x = 0, .y = 1.5, .z = 0 };
    cam.orbitOffset(target, 3.5, 0.6, 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), cam.pos.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), cam.pos.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), cam.pos.z, 1e-5);
    // still looking straight down -Z, not turned toward the target
    try std.testing.expectApproxEqAbs(@as(f32, -1), cam.forward().z, 1e-5);
}

test "addLook gates the mouse and clamps pitch" {
    var input: Input = .{};
    var cam: Camera = .{ .pitch_min = -1, .pitch_max = 1 };

    input.devices.keyboard = false;
    input.mouse_dx = 100;
    input.mouse_dy = 100;
    cam.addLook(&input, 0.016, .{});
    try std.testing.expectEqual(@as(f32, 0), cam.yaw);

    input.devices.keyboard = true;
    cam.addLook(&input, 0.016, .{ .mouse = 0.01 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), cam.yaw, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), cam.pitch, 1e-6);
}
