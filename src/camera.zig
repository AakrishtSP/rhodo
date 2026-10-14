const std = @import("std");
const math = @import("math.zig");

// Engine-owned camera. The sandbox drives pos/yaw/pitch from input; the renderer
// derives view/projection from it and binds it once per frame (renderer.setCamera)
// instead of threading it through every draw call.
pub const Camera = struct {
    pos: math.Vec3 = .{ .x = 0, .y = 0, .z = 4 },
    yaw: f32 = 0, // radians around +Y
    pitch: f32 = 0, // radians around camera right; positive looks up
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
