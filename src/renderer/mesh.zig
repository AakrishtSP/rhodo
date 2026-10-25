const std = @import("std");
const cgltf = @import("cgltf");
// translate-c types C enum constants as c_int but functions return c_uint.
const cgltf_success: cgltf.cgltf_result = @intCast(cgltf.cgltf_result_success);

pub const Vertex = struct {
    pos: [3]f32,
    normal: [3]f32,
};

pub const Mesh = struct {
    vertices: []Vertex,
    indices: []u32,

    pub fn deinit(self: Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};

// cgltf (vendor/cgltf) — single-header glTF 2.0 parser. This is the only
// mesh format the engine loads now; the OBJ/tiny_obj_c path is gone.
//
// ponytail: concatenates every primitive of every mesh in the file into one
// Mesh, ignoring node transforms/hierarchy entirely. Correct for a single
// exported object (Blender "export selected", one mesh). A multi-node scene
// (several positioned instances, or a rig) needs the node graph walked with
// cgltf_node_transform_world per node — upgrade here when a glTF with more
// than one entry in data.nodes shows up.
pub fn loadGltf(allocator: std.mem.Allocator, path: [:0]const u8) !Mesh {
    var options: cgltf.cgltf_options = std.mem.zeroes(cgltf.cgltf_options);
    var data: ?*cgltf.cgltf_data = null;

    if (cgltf.cgltf_parse_file(&options, path.ptr, &data) != cgltf_success) {
        return error.GltfParseFailed;
    }
    defer cgltf.cgltf_free(data);

    if (cgltf.cgltf_load_buffers(&options, data, path.ptr) != cgltf_success) {
        return error.GltfLoadBuffersFailed;
    }

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(allocator);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(allocator);

    var mi: usize = 0;
    while (mi < data.?.meshes_count) : (mi += 1) {
        const mesh = data.?.meshes[mi];
        var pi: usize = 0;
        while (pi < mesh.primitives_count) : (pi += 1) {
            const prim = &mesh.primitives[pi];
            const pos_acc = cgltf.cgltf_find_accessor(prim, cgltf.cgltf_attribute_type_position, 0) orelse continue;
            const norm_acc = cgltf.cgltf_find_accessor(prim, cgltf.cgltf_attribute_type_normal, 0);

            const base: u32 = @intCast(vertices.items.len);
            var vi: usize = 0;
            while (vi < pos_acc.*.count) : (vi += 1) {
                var vert: Vertex = .{ .pos = .{ 0, 0, 0 }, .normal = .{ 0, 0, 0 } };
                _ = cgltf.cgltf_accessor_read_float(pos_acc, vi, &vert.pos[0], 3);
                if (norm_acc) |na| _ = cgltf.cgltf_accessor_read_float(na, vi, &vert.normal[0], 3);
                try vertices.append(allocator, vert);
            }

            if (prim.indices) |idx_acc| {
                var ii: usize = 0;
                while (ii < idx_acc.*.count) : (ii += 1) {
                    const idx = cgltf.cgltf_accessor_read_index(idx_acc, ii);
                    try indices.append(allocator, base + @as(u32, @intCast(idx)));
                }
            } else {
                // Non-indexed primitive: cgltf doesn't synthesize indices,
                // so number the verts we just appended sequentially.
                var ii: usize = 0;
                while (ii < pos_acc.*.count) : (ii += 1) {
                    try indices.append(allocator, base + @as(u32, @intCast(ii)));
                }
            }
        }
    }

    return .{
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

// Unit cube, unchanged — pure Zig, no library involved.
pub fn cube(allocator: std.mem.Allocator) !Mesh {
    const faces = [_]struct { n: [3]f32, q: [4][3]f32 }{
        .{ .n = .{ 0, 0, 1 }, .q = .{ .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } } },
        .{ .n = .{ 0, 0, -1 }, .q = .{ .{ 1, -1, -1 }, .{ -1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 } } },
        .{ .n = .{ 1, 0, 0 }, .q = .{ .{ 1, -1, 1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 1 } } },
        .{ .n = .{ -1, 0, 0 }, .q = .{ .{ -1, -1, -1 }, .{ -1, -1, 1 }, .{ -1, 1, 1 }, .{ -1, 1, -1 } } },
        .{ .n = .{ 0, 1, 0 }, .q = .{ .{ -1, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 } } },
        .{ .n = .{ 0, -1, 0 }, .q = .{ .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 1 }, .{ -1, -1, 1 } } },
    };
    var verts = try allocator.alloc(Vertex, 24);
    var indices = try allocator.alloc(u32, 36);
    for (faces, 0..) |f, fi| {
        for (f.q, 0..) |p, vi| verts[fi * 4 + vi] = .{ .pos = p, .normal = f.n };
        const base: u32 = @intCast(fi * 4);
        const tri = [_]u32{ 0, 1, 2, 0, 2, 3 };
        for (tri, 0..) |t, ti| indices[fi * 6 + ti] = base + t;
    }
    return .{ .vertices = verts, .indices = indices };
}

// Pure-Zig primitives matching the physics shapes (no assets needed). Sizes:
//   cube      unit, [-1, 1] on every axis
//   sphere    radius 1
//   cylinder  radius 1, half height 1
//   quad      [-1, 1] in XZ at y=0, normal +Y (ground/plane)
//   capsule   sized: radius + straight half height (build it at the body size;
//             non-uniform scaling a unit capsule distorts the caps)
// Draw the unit meshes with transforms[].scale from the physics sync: the
// scale is the shape's bounds, so no per-shape branch in the game.
pub fn sphere(allocator: std.mem.Allocator) !Mesh {
    return lathe(allocator, 1, 0);
}

pub fn capsule(allocator: std.mem.Allocator, radius: f32, half_height: f32) !Mesh {
    return lathe(allocator, radius, half_height);
}

fn lathe(allocator: std.mem.Allocator, radius: f32, half_height: f32) !Mesh {
    const rings: usize = 16;
    const segs: usize = 24;
    var verts = try allocator.alloc(Vertex, (rings + 1) * (segs + 1));
    var indices = try allocator.alloc(u32, rings * segs * 6);

    for (0..rings + 1) |i| {
        const phi = -std.math.pi * 0.5 + std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rings));
        const sp = @sin(phi);
        const cp = @cos(phi);
        const cap_offset = if (sp > 0) half_height else if (sp < 0) -half_height else 0;
        for (0..segs + 1) |j| {
            const theta = 2 * std.math.pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(segs));
            const dir = [3]f32{ cp * @cos(theta), sp, cp * @sin(theta) };
            verts[i * (segs + 1) + j] = .{
                .pos = .{
                    dir[0] * radius,
                    dir[1] * radius + cap_offset,
                    dir[2] * radius,
                },
                .normal = dir,
            };
        }
    }

    var ii: usize = 0;
    for (0..rings) |i| {
        for (0..segs) |j| {
            const a: u32 = @intCast(i * (segs + 1) + j);
            const b = a + 1;
            const c: u32 = @intCast((i + 1) * (segs + 1) + j);
            const d = c + 1;
            indices[ii..][0..6].* = .{ a, c, b, b, c, d };
            ii += 6;
        }
    }
    return .{ .vertices = verts, .indices = indices };
}

pub fn cylinder(allocator: std.mem.Allocator) !Mesh {
    const segs: usize = 24;
    const ring = segs + 1;
    const side_n = 2 * ring;
    const top_center: u32 = @intCast(side_n);
    const top_rim: u32 = top_center + 1;
    const bottom_center: u32 = top_rim + @as(u32, @intCast(ring));
    const bottom_rim: u32 = bottom_center + 1;

    var verts = try allocator.alloc(Vertex, side_n + 2 + 2 * ring);
    var indices = try allocator.alloc(u32, segs * 6 * 2);
    var ii: usize = 0;

    for (0..segs + 1) |j| {
        const theta = 2 * std.math.pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(segs));
        const n = [3]f32{ @cos(theta), 0, @sin(theta) };
        verts[j] = .{ .pos = .{ n[0], -1, n[2] }, .normal = n };
        verts[ring + j] = .{ .pos = .{ n[0], 1, n[2] }, .normal = n };
        verts[top_rim + j] = .{ .pos = .{ n[0], 1, n[2] }, .normal = .{ 0, 1, 0 } };
        verts[bottom_rim + j] = .{ .pos = .{ n[0], -1, n[2] }, .normal = .{ 0, -1, 0 } };
    }
    verts[top_center] = .{ .pos = .{ 0, 1, 0 }, .normal = .{ 0, 1, 0 } };
    verts[bottom_center] = .{ .pos = .{ 0, -1, 0 }, .normal = .{ 0, -1, 0 } };

    for (0..segs) |j| {
        const a: u32 = @intCast(j);
        const b = a + 1;
        const c: u32 = @intCast(ring + j);
        const d = c + 1;
        indices[ii..][0..6].* = .{ a, c, b, b, c, d };
        ii += 6;
    }
    for (0..segs) |j| {
        const p0 = top_rim + @as(u32, @intCast(j));
        const p1 = p0 + 1;
        indices[ii..][0..3].* = .{ top_center, p1, p0 };
        indices[ii + 3 ..][0..3].* = .{ bottom_center, bottom_rim + @as(u32, @intCast(j)), bottom_rim + @as(u32, @intCast(j)) + 1 };
        ii += 6;
    }
    return .{ .vertices = verts, .indices = indices };
}

pub fn quad(allocator: std.mem.Allocator) !Mesh {
    const n = [3]f32{ 0, 1, 0 };
    const verts = try allocator.dupe(Vertex, &.{
        .{ .pos = .{ -1, 0, 1 }, .normal = n },
        .{ .pos = .{ 1, 0, 1 }, .normal = n },
        .{ .pos = .{ 1, 0, -1 }, .normal = n },
        .{ .pos = .{ -1, 0, -1 }, .normal = n },
    });
    const indices = try allocator.dupe(u32, &.{ 0, 1, 2, 0, 2, 3 });
    return .{ .vertices = verts, .indices = indices };
}

test "primitives are indexed, non-empty, and in range" {
    const a = std.testing.allocator;
    const meshes = .{
        try sphere(a),
        try cylinder(a),
        try capsule(a, 0.5, 1.0),
        try quad(a),
    };
    inline for (meshes) |m| {
        defer m.deinit(a);
        try std.testing.expect(m.vertices.len > 0);
        try std.testing.expect(m.indices.len > 0);
        for (m.indices) |i| try std.testing.expect(i < m.vertices.len);
    }
}

// One runnable check: a self-contained glTF (positions embedded as a base64
// data URI, non-indexed triangle) exercises cgltf_parse + cgltf_load_buffers
// + cgltf_find_accessor + cgltf_accessor_read_float — the same calls
// loadGltf makes — without touching disk.
test "cgltf parses an embedded one-triangle glTF" {
    const doc =
        \\{"asset":{"version":"2.0"},
        \\"buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA"}],
        \\"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}]}
    ;
    var options: cgltf.cgltf_options = std.mem.zeroes(cgltf.cgltf_options);
    var data: ?*cgltf.cgltf_data = null;
    try std.testing.expectEqual(cgltf_success, cgltf.cgltf_parse(&options, doc.ptr, doc.len, &data));
    defer cgltf.cgltf_free(data);
    try std.testing.expectEqual(cgltf_success, cgltf.cgltf_load_buffers(&options, data, null));

    try std.testing.expectEqual(@as(usize, 1), data.?.meshes_count);
    const prim = &data.?.meshes[0].primitives[0];
    const pos_acc = cgltf.cgltf_find_accessor(prim, cgltf.cgltf_attribute_type_position, 0).?;
    try std.testing.expectEqual(@as(usize, 3), pos_acc.*.count);

    var p: [3]f32 = undefined;
    _ = cgltf.cgltf_accessor_read_float(pos_acc, 1, &p[0], 3);
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, p);
}
