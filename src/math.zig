const std = @import("std");

pub const Vec2 = struct { x: f32, y: f32 };
pub const Vec4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    /// Inverse of a unit rotation quaternion.
    pub fn conjugate(q: Vec4) Vec4 {
        return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
    }
};

// Rigid transform: world position, unit quaternion (x, y, z, w), scale.
// Physics writes these; Mat4.fromTransform composes them for rendering.
pub const Transform = struct {
    pos: Vec3,
    rot: Vec4,
    scale: Vec3,

    /// Full local point -> world (T*R*S). Only use when `scale` is a real
    /// entity scale; physics transforms store shape bounds there. For hitbox /
    /// muzzle / weak-spot offsets from a physics transform, use `offset`.
    pub fn point(self: Transform, local: Vec3) Vec3 {
        const scaled = Vec3{
            .x = local.x * self.scale.x,
            .y = local.y * self.scale.y,
            .z = local.z * self.scale.z,
        };
        return self.pos.add(scaled.rotateByQuat(self.rot));
    }

    /// Local point -> world using position + rotation only (ignores scale).
    /// This is the one for entity-local offsets from `Physics.transform`.
    pub fn offset(self: Transform, local: Vec3) Vec3 {
        return self.pos.add(local.rotateByQuat(self.rot));
    }

    /// Local direction -> world (rotation only; ignores position and scale).
    pub fn direction(self: Transform, local: Vec3) Vec3 {
        return local.rotateByQuat(self.rot);
    }

    /// World point -> local (inverse of `offset`).
    pub fn inverseOffset(self: Transform, world: Vec3) Vec3 {
        return world.sub(self.pos).rotateByQuat(self.rot.conjugate());
    }

    /// World direction -> local (inverse of `direction`).
    pub fn inverseDirection(self: Transform, world: Vec3) Vec3 {
        return world.rotateByQuat(self.rot.conjugate());
    }
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    // Rotate v by unit quaternion q (x, y, z, w).
    pub fn rotateByQuat(v: Vec3, q: Vec4) Vec3 {
        const qv = Vec3{ .x = q.x, .y = q.y, .z = q.z };
        const t = qv.cross(v).scale(2);
        return v.add(t.scale(q.w)).add(qv.cross(t));
    }
    pub fn normalize(a: Vec3) Vec3 {
        const len = @sqrt(a.dot(a));
        if (len == 0) return a;
        return .{ .x = a.x / len, .y = a.y / len, .z = a.z / len };
    }
};

// Column-major 4x4, m[col*4 + row] — the layout Vulkan/GLSL expect. mul does
// standard a*b. HLSL's mul(M,v) is row-based, so push transpose() to the shader.
pub const Mat4 = struct {
    m: [16]f32,

    pub const identity: Mat4 = .{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |j| {
            for (0..4) |i| {
                var sum: f32 = 0;
                for (0..4) |k| sum += a.m[k * 4 + i] * b.m[j * 4 + k];
                r.m[j * 4 + i] = sum;
            }
        }
        return r;
    }

    pub fn transpose(a: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |c| for (0..4) |row| {
            r.m[c * 4 + row] = a.m[row * 4 + c];
        };
        return r;
    }

    // Vulkan clip space: depth 0..1, Y flipped (negated m[1][1]).
    pub fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fovy_rad / 2.0);
        var r: Mat4 = .{ .m = @splat(0) };
        r.m[0] = f / aspect;
        r.m[5] = -f;
        r.m[10] = far / (near - far);
        r.m[11] = -1;
        r.m[14] = (near * far) / (near - far);
        return r;
    }

    pub fn lookAt(eye: Vec3, center: Vec3, up: Vec3) Mat4 {
        const f = center.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return .{ .m = .{
            s.x,         u.x,         -f.x,       0,
            s.y,         u.y,         -f.y,       0,
            s.z,         u.z,         -f.z,       0,
            -s.dot(eye), -u.dot(eye), f.dot(eye), 1,
        } };
    }

    pub fn rotationY(a: f32) Mat4 {
        const c = @cos(a);
        const s = @sin(a);
        return .{ .m = .{
            c, 0, -s, 0,
            0, 1, 0,  0,
            s, 0, c,  0,
            0, 0, 0,  1,
        } };
    }

    // Vulkan orthographic: x maps left..right to -1..1, y maps bottom..top to
    // +1..-1 (world +Y up, matching perspective), z maps near..far to 0..1.
    pub fn orthographic(l: f32, r: f32, b: f32, t: f32, n: f32, f: f32) Mat4 {
        var m: Mat4 = .{ .m = @splat(0) };
        m.m[0] = 2.0 / (r - l);
        m.m[5] = 2.0 / (b - t);
        m.m[10] = 1.0 / (f - n);
        m.m[12] = -(r + l) / (r - l);
        m.m[13] = (b + t) / (t - b);
        m.m[14] = -n / (f - n);
        m.m[15] = 1.0;
        return m;
    }

    pub fn translate(x: f32, y: f32, z: f32) Mat4 {
        var m = identity;
        m.m[12] = x;
        m.m[13] = y;
        m.m[14] = z;
        return m;
    }

    pub fn scale(x: f32, y: f32, z: f32) Mat4 {
        var m: Mat4 = .{ .m = @splat(0) };
        m.m[0] = x;
        m.m[5] = y;
        m.m[10] = z;
        m.m[15] = 1.0;
        return m;
    }

    // World-space AABB of a box with center pos, unit-quaternion rot (x,y,z,w),
    // and half extents half. Tight even when rotated (unlike pos +/- half):
    // each world half-extent sums the absolute rotated local axes.
    pub fn orientedBoxAabb(pos: Vec3, rot: Vec4, half: Vec3) struct { min: Vec3, max: Vec3 } {
        const qx = rot.x;
        const qy = rot.y;
        const qz = rot.z;
        const qw = rot.w;
        const xx = qx * qx;
        const yy = qy * qy;
        const zz = qz * qz;
        const xy = qx * qy;
        const xz = qx * qz;
        const yz = qy * qz;
        const wx = qw * qx;
        const wy = qw * qy;
        const wz = qw * qz;
        const r00 = 1 - 2 * (yy + zz);
        const r01 = 2 * (xy - wz);
        const r02 = 2 * (xz + wy);
        const r10 = 2 * (xy + wz);
        const r11 = 1 - 2 * (xx + zz);
        const r12 = 2 * (yz - wx);
        const r20 = 2 * (xz - wy);
        const r21 = 2 * (yz + wx);
        const r22 = 1 - 2 * (xx + yy);
        const wh = Vec3{
            .x = @abs(r00) * half.x + @abs(r01) * half.y + @abs(r02) * half.z,
            .y = @abs(r10) * half.x + @abs(r11) * half.y + @abs(r12) * half.z,
            .z = @abs(r20) * half.x + @abs(r21) * half.y + @abs(r22) * half.z,
        };
        return .{ .min = pos.sub(wh), .max = pos.add(wh) };
    }

    /// Clip-space transform -> top-left pixel coordinates (Vulkan viewport:
    /// NDC y=-1 is the top). Null behind the camera or outside depth 0..1.
    pub fn projectPoint(vp: Mat4, p: Vec3, width: f32, height: f32) ?Vec2 {
        const m = vp.m;
        const x = m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12];
        const y = m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13];
        const z = m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14];
        const w = m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15];
        if (w <= 0) return null;
        const ndc_z = z / w;
        if (ndc_z < 0 or ndc_z > 1) return null;
        return .{
            .x = (x / w + 1.0) * 0.5 * width,
            .y = (y / w + 1.0) * 0.5 * height,
        };
    }

    // Compose translation * rotation * scale from a Transform. rot is a unit
    // quaternion (x, y, z, w); columns are scaled so M = T*R*S.
    pub fn fromTransform(t: Transform) Mat4 {
        const qx = t.rot.x;
        const qy = t.rot.y;
        const qz = t.rot.z;
        const qw = t.rot.w;
        const xx = qx * qx;
        const yy = qy * qy;
        const zz = qz * qz;
        const xy = qx * qy;
        const xz = qx * qz;
        const yz = qy * qz;
        const wx = qw * qx;
        const wy = qw * qy;
        const wz = qw * qz;
        const sx = t.scale.x;
        const sy = t.scale.y;
        const sz = t.scale.z;
        return .{ .m = .{
            (1 - 2 * (yy + zz)) * sx, 2 * (xy + wz) * sx,       2 * (xz - wy) * sx,       0,
            2 * (xy - wz) * sy,       (1 - 2 * (xx + zz)) * sy, 2 * (yz + wx) * sy,       0,
            2 * (xz + wy) * sz,       2 * (yz - wx) * sz,       (1 - 2 * (xx + yy)) * sz, 0,
            t.pos.x,                  t.pos.y,                  t.pos.z,                  1,
        } };
    }
};

test "identity mul round-trips" {
    const v = Mat4.identity.mul(Mat4.rotationY(1.2345));
    const r = Mat4.rotationY(1.2345);
    for (v.m, r.m) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);
}

test "orthographic maps corners to clip edges" {
    // ortho(0,2, 0,2, 0,1): x 0..2 -> -1..1, y 0(bottom)..2(top) -> +1..-1.
    const o = Mat4.orthographic(0, 2, 0, 2, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), o.m[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), o.m[5], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), o.m[10], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), o.m[12], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), o.m[13], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), o.m[15], 1e-6);
}

test "fromTransform composes T*R*S" {
    const t = Transform{
        .pos = .{ .x = 1, .y = 2, .z = 3 },
        .rot = .{ .x = 0, .y = 0, .z = 0, .w = 1 },
        .scale = .{ .x = 2, .y = 2, .z = 2 },
    };
    const got = Mat4.fromTransform(t);
    const want = Mat4.translate(1, 2, 3).mul(Mat4.scale(2, 2, 2));
    for (got.m, want.m) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-6);

    // 90 degrees about Y maps +X to -Z, matching rotationY.
    const h = @sqrt(@as(f32, 0.5));
    const r = Mat4.fromTransform(.{
        .pos = .{ .x = 0, .y = 0, .z = 0 },
        .rot = .{ .x = 0, .y = h, .z = 0, .w = h },
        .scale = .{ .x = 1, .y = 1, .z = 1 },
    });
    const want_r = Mat4.rotationY(std.math.pi / 2.0);
    for (r.m, want_r.m) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-5);
}

test "orientedBoxAabb is tight when rotated" {
    const id = Vec4{ .x = 0, .y = 0, .z = 0, .w = 1 };
    const a = Mat4.orientedBoxAabb(
        .{ .x = 1, .y = 2, .z = 3 },
        id,
        .{ .x = 1, .y = 2, .z = 3 },
    );
    try std.testing.expectEqual(Vec3{ .x = 0, .y = 0, .z = 0 }, a.min);
    try std.testing.expectEqual(Vec3{ .x = 2, .y = 4, .z = 6 }, a.max);

    // 90 degrees about Y swaps x/z extents.
    const h = @sqrt(@as(f32, 0.5));
    const b = Mat4.orientedBoxAabb(
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = h, .z = 0, .w = h },
        .{ .x = 1, .y = 2, .z = 3 },
    );
    try std.testing.expectApproxEqAbs(@as(f32, -3), b.min.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -2), b.min.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), b.min.z, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3), b.max.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), b.max.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), b.max.z, 1e-5);
}

test "projectPoint maps center and rejects behind-camera points" {
    const center = Mat4.projectPoint(Mat4.identity, .{ .x = 0, .y = 0, .z = 0.5 }, 800, 600);
    try std.testing.expect(center != null);
    try std.testing.expectApproxEqAbs(@as(f32, 400), center.?.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), center.?.y, 1e-5);

    const proj = Mat4.perspective(std.math.pi / 2.0, 1, 0.1, 100);
    try std.testing.expect(Mat4.projectPoint(proj, .{ .x = 0, .y = 0, .z = 1 }, 800, 600) == null);
    const front = Mat4.projectPoint(proj, .{ .x = 0, .y = 0, .z = -1 }, 800, 600);
    try std.testing.expect(front != null);
    try std.testing.expectApproxEqAbs(@as(f32, 400), front.?.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 300), front.?.y, 1e-5);
}

test "Transform maps local points and directions" {
    const h = @sqrt(@as(f32, 0.5));
    const t = Transform{
        .pos = .{ .x = 10, .y = 0, .z = 0 },
        .rot = .{ .x = 0, .y = h, .z = 0, .w = h }, // 90deg about Y
        .scale = .{ .x = 2, .y = 3, .z = 4 },
    };
    // local +X scales to 2, rotates to -Z, then translates
    const p = t.point(.{ .x = 1, .y = 0, .z = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), p.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -2), p.z, 1e-5);

    // offset ignores scale (physics transforms store shape bounds in scale)
    const off = t.offset(.{ .x = 1, .y = 0, .z = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 10), off.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), off.z, 1e-5);

    const d = t.direction(.{ .x = 1, .y = 0, .z = 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), d.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), d.z, 1e-5);

    // world -> local round-trips (offset/direction ignore scale)
    const local = t.inverseOffset(off);
    try std.testing.expectApproxEqAbs(@as(f32, 1), local.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), local.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), local.z, 1e-5);
    const local_dir = t.inverseDirection(d);
    try std.testing.expectApproxEqAbs(@as(f32, 1), local_dir.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), local_dir.z, 1e-5);
}

test "rotateByQuat turns +X to -Z on 90deg Y" {
    const h = @sqrt(@as(f32, 0.5));
    const v = Vec3{ .x = 1, .y = 0, .z = 0 };
    const got = v.rotateByQuat(.{ .x = 0, .y = h, .z = 0, .w = h });
    try std.testing.expectApproxEqAbs(@as(f32, 0), got.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), got.y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1), got.z, 1e-5);
}
