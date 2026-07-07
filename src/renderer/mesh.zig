const std = @import("std");
const cgltf = @cImport({
    @cInclude("cgltf.h");
});

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

    if (cgltf.cgltf_parse_file(&options, path.ptr, &data) != cgltf.cgltf_result_success) {
        return error.GltfParseFailed;
    }
    defer cgltf.cgltf_free(data);

    if (cgltf.cgltf_load_buffers(&options, data, path.ptr) != cgltf.cgltf_result_success) {
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
    try std.testing.expectEqual(cgltf.cgltf_result_success, cgltf.cgltf_parse(&options, doc.ptr, doc.len, &data));
    defer cgltf.cgltf_free(data);
    try std.testing.expectEqual(cgltf.cgltf_result_success, cgltf.cgltf_load_buffers(&options, data, null));

    try std.testing.expectEqual(@as(usize, 1), data.?.meshes_count);
    const prim = &data.?.meshes[0].primitives[0];
    const pos_acc = cgltf.cgltf_find_accessor(prim, cgltf.cgltf_attribute_type_position, 0).?;
    try std.testing.expectEqual(@as(usize, 3), pos_acc.*.count);

    var p: [3]f32 = undefined;
    _ = cgltf.cgltf_accessor_read_float(pos_acc, 1, &p[0], 3);
    try std.testing.expectEqual([3]f32{ 1, 0, 0 }, p);
}
