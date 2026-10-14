const std = @import("std");

pub const Vec4 = struct { x: f32, y: f32, z: f32, w: f32 };

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
        var r: Mat4 = .{ .m = .{0} ** 16 };
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
        var m: Mat4 = .{ .m = .{0} ** 16 };
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
        var m: Mat4 = .{ .m = .{0} ** 16 };
        m.m[0] = x;
        m.m[5] = y;
        m.m[10] = z;
        m.m[15] = 1.0;
        return m;
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
