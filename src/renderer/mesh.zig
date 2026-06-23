const std = @import("std");

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

// Minimal Wavefront OBJ: v, vn, f. Faces are fan-triangulated (handles tris,
// quads, n-gons). Each unique v//vn pair becomes one vertex (deduped). vt is
// ignored — no UVs on the mesh path yet. ponytail: no materials/smoothing
// groups; add when a model needs them.
pub fn loadObj(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Mesh {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(src);
    return parseObj(allocator, src);
}

pub fn parseObj(allocator: std.mem.Allocator, src: []const u8) !Mesh {
    var positions: std.ArrayList([3]f32) = .empty;
    defer positions.deinit(allocator);
    var normals: std.ArrayList([3]f32) = .empty;
    defer normals.deinit(allocator);

    var vertices: std.ArrayList(Vertex) = .empty;
    errdefer vertices.deinit(allocator);
    var indices: std.ArrayList(u32) = .empty;
    errdefer indices.deinit(allocator);

    // "p//n" key -> emitted vertex index, so shared corners reuse one vertex.
    var seen: std.StringHashMap(u32) = .init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var lines = std.mem.tokenizeScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const tag = tok.next() orelse continue;

        if (std.mem.eql(u8, tag, "v")) {
            try positions.append(allocator, try readVec3(&tok));
        } else if (std.mem.eql(u8, tag, "vn")) {
            try normals.append(allocator, try readVec3(&tok));
        } else if (std.mem.eql(u8, tag, "f")) {
            // Collect this face's corner-vertex indices, then fan-triangulate.
            var face: std.ArrayList(u32) = .empty;
            defer face.deinit(allocator);
            while (tok.next()) |corner| {
                const idx = try resolveCorner(allocator, corner, positions.items, normals.items, &vertices, &seen);
                try face.append(allocator, idx);
            }
            if (face.items.len < 3) return error.DegenerateFace;
            for (1..face.items.len - 1) |i| {
                try indices.appendSlice(allocator, &.{ face.items[0], face.items[i], face.items[i + 1] });
            }
        }
    }

    return .{
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

fn readVec3(tok: *std.mem.TokenIterator(u8, .any)) ![3]f32 {
    var v: [3]f32 = undefined;
    for (&v) |*c| c.* = try std.fmt.parseFloat(f32, tok.next() orelse return error.BadVertex);
    return v;
}

// "p/t/n" (t and n optional). 1-based, negative = relative-from-end.
fn resolveCorner(
    allocator: std.mem.Allocator,
    corner: []const u8,
    positions: []const [3]f32,
    normals: []const [3]f32,
    vertices: *std.ArrayList(Vertex),
    seen: *std.StringHashMap(u32),
) !u32 {
    var parts = std.mem.splitScalar(u8, corner, '/');
    const p_str = parts.next() orelse return error.BadFace;
    _ = parts.next(); // skip vt
    const n_str = parts.next();

    if (seen.get(corner)) |existing| return existing;

    const p_idx = try objIndex(p_str, positions.len);
    var vert: Vertex = .{ .pos = positions[p_idx], .normal = .{ 0, 0, 0 } };
    if (n_str) |ns| if (ns.len > 0) {
        vert.normal = normals[try objIndex(ns, normals.len)];
    };

    const new_idx: u32 = @intCast(vertices.items.len);
    try vertices.append(allocator, vert);
    try seen.put(try allocator.dupe(u8, corner), new_idx);
    return new_idx;
}

fn objIndex(s: []const u8, count: usize) !usize {
    const raw = try std.fmt.parseInt(i64, s, 10);
    if (raw > 0) return @intCast(raw - 1);
    if (raw < 0) return @intCast(@as(i64, @intCast(count)) + raw);
    return error.ZeroIndex;
}

// Unit cube, 24 verts (per-face normals), 36 indices. Fallback when the obj
// file is missing so the renderer always has something to draw.
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

test "parse one-triangle obj" {
    const obj =
        \\v 0 0 0
        \\v 1 0 0
        \\v 0 1 0
        \\vn 0 0 1
        \\f 1//1 2//1 3//1
    ;
    const m = try parseObj(std.testing.allocator, obj);
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), m.vertices.len);
    try std.testing.expectEqual(@as(usize, 3), m.indices.len);
    try std.testing.expectEqual(@as(f32, 1), m.vertices[1].pos[0]);
}
