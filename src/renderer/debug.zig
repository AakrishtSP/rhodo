const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vk/context.zig").Context;
const pipeline_mod = @import("vk/pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const Buffer = @import("vk/buffer.zig").Buffer;
const math = @import("../math.zig");

pub const LineVertex = struct { pos: math.Vec3, color: math.Vec3 };

// ponytail: ceiling 8192 lines, no sorting, no index buffer. Grow the array
// (and the GPU buffer in init) when a frame needs more.
const max_lines = 8192;
const max_verts = max_lines * 2;

const line_bindings = [_]vk.VertexInputBindingDescription{.{
    .binding = 0,
    .stride = @sizeOf(LineVertex),
    .input_rate = .vertex,
}};
const line_attributes = [_]vk.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(LineVertex, "pos") },
    .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(LineVertex, "color") },
};
// Same 64-byte MVP push constant as the mesh pipeline, so flush pushes viewProj.
const line_push = [_]vk.PushConstantRange{.{
    .stage_flags = .{ .vertex = true },
    .offset = 0,
    .size = @sizeOf(math.Mat4),
}};
const line_config: pipeline_mod.Config = .{
    .bindings = &line_bindings,
    .attributes = &line_attributes,
    .push_constant_ranges = &line_push,
    .topology = .line_list,
    .depth_test = false,
    .cull_back = false,
};

// CPU line list uploaded and drawn once per frame. Append with line()/aabb()
// any time before endFrame; flush() runs automatically at the end of the frame
// (inside the render pass, depth off, so lines draw on top).
pub const DebugDraw = struct {
    pipeline: Pipeline,
    buffer: Buffer,
    verts: [max_verts]LineVertex = undefined,
    count: u32 = 0,

    // Line shader sources (also registered for hot-reload by the renderer).
    pub const vert_path = "shaders/line.vert.spv";
    pub const frag_path = "shaders/line.frag.spv";

    pub fn init(ctx: *const Context, io: std.Io, format: vk.Format) !DebugDraw {
        return .{
            .pipeline = try Pipeline.init(ctx, io, format, vert_path, frag_path, line_config),
            .buffer = try Buffer.create(
                ctx,
                @sizeOf(LineVertex) * max_verts,
                .{ .vertex_buffer = true },
                .{ .host_visible = true, .host_coherent = true },
            ),
        };
    }

    pub fn deinit(self: *DebugDraw, ctx: *const Context) void {
        self.buffer.deinit(ctx);
        self.pipeline.deinit(ctx);
    }

    pub fn line(self: *DebugDraw, a: math.Vec3, b: math.Vec3, color: math.Vec3) void {
        if (self.count + 2 > max_verts) return;
        self.verts[self.count] = .{ .pos = a, .color = color };
        self.verts[self.count + 1] = .{ .pos = b, .color = color };
        self.count += 2;
    }

    pub fn aabb(self: *DebugDraw, min: math.Vec3, max: math.Vec3, color: math.Vec3) void {
        self.wire(
            .{ .x = min.x, .y = min.y, .z = min.z },
            .{ .x = max.x, .y = min.y, .z = min.z },
            .{ .x = max.x, .y = max.y, .z = min.z },
            .{ .x = min.x, .y = max.y, .z = min.z },
            .{ .x = min.x, .y = min.y, .z = max.z },
            .{ .x = max.x, .y = min.y, .z = max.z },
            .{ .x = max.x, .y = max.y, .z = max.z },
            .{ .x = min.x, .y = max.y, .z = max.z },
            color,
        );
    }

    // Oriented box gizmo: the true rotated edges (vs aabb's world bounds).
    pub fn obb(self: *DebugDraw, pos: math.Vec3, rot: math.Vec4, half: math.Vec3, color: math.Vec3) void {
        const hx = math.Vec3{ .x = half.x, .y = 0, .z = 0 };
        const hy = math.Vec3{ .x = 0, .y = half.y, .z = 0 };
        const hz = math.Vec3{ .x = 0, .y = 0, .z = half.z };
        const px = hx.rotateByQuat(rot);
        const py = hy.rotateByQuat(rot);
        const pz = hz.rotateByQuat(rot);
        self.wire(
            pos.sub(px).sub(py).sub(pz),
            pos.add(px).sub(py).sub(pz),
            pos.add(px).add(py).sub(pz),
            pos.sub(px).add(py).sub(pz),
            pos.sub(px).sub(py).add(pz),
            pos.add(px).sub(py).add(pz),
            pos.add(px).add(py).add(pz),
            pos.sub(px).add(py).add(pz),
            color,
        );
    }

    fn wire(
        self: *DebugDraw,
        c000: math.Vec3,
        c100: math.Vec3,
        c110: math.Vec3,
        c010: math.Vec3,
        c001: math.Vec3,
        c101: math.Vec3,
        c111: math.Vec3,
        c011: math.Vec3,
        color: math.Vec3,
    ) void {
        self.line(c000, c100, color);
        self.line(c100, c110, color);
        self.line(c110, c010, color);
        self.line(c010, c000, color);
        self.line(c001, c101, color);
        self.line(c101, c111, color);
        self.line(c111, c011, color);
        self.line(c011, c001, color);
        self.line(c000, c001, color);
        self.line(c100, c101, color);
        self.line(c110, c111, color);
        self.line(c010, c011, color);
    }

    fn ring(self: *DebugDraw, center: math.Vec3, u: math.Vec3, v: math.Vec3, radius: f32, color: math.Vec3) void {
        const n = 20;
        var prev = center.add(u.scale(radius));
        for (1..n + 1) |i| {
            const a = 2 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const p = center.add(u.scale(@cos(a) * radius)).add(v.scale(@sin(a) * radius));
            self.line(prev, p, color);
            prev = p;
        }
    }

    fn arc(self: *DebugDraw, center: math.Vec3, up: math.Vec3, side: math.Vec3, radius: f32, color: math.Vec3) void {
        const n = 8;
        var prev = center.add(side.scale(radius));
        for (1..n + 1) |i| {
            const a = std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const p = center.add(side.scale(@cos(a) * radius)).add(up.scale(@sin(a) * radius));
            self.line(prev, p, color);
            prev = p;
        }
    }

    /// Wire sphere: three great circles.
    pub fn sphere(self: *DebugDraw, center: math.Vec3, radius: f32, color: math.Vec3) void {
        self.ring(center, unit_x, unit_y, radius, color);
        self.ring(center, unit_x, unit_z, radius, color);
        self.ring(center, unit_y, unit_z, radius, color);
    }

    /// Upright-around-`axis` cylinder (rotated by the body quat).
    pub fn cylinder(self: *DebugDraw, center: math.Vec3, axis: math.Vec3, radius: f32, half_height: f32, color: math.Vec3) void {
        const b = basis(axis);
        const a = axis.normalize();
        const top = center.add(a.scale(half_height));
        const bot = center.sub(a.scale(half_height));
        self.ring(top, b.u, b.v, radius, color);
        self.ring(bot, b.u, b.v, radius, color);
        for ([_]math.Vec3{ b.u, b.u.scale(-1), b.v, b.v.scale(-1) }) |d| {
            self.line(bot.add(d.scale(radius)), top.add(d.scale(radius)), color);
        }
    }

    /// Capsule: two rings, four side lines, and a cap arc per side per plane.
    pub fn capsule(self: *DebugDraw, center: math.Vec3, axis: math.Vec3, radius: f32, half_height: f32, color: math.Vec3) void {
        const b = basis(axis);
        const a = axis.normalize();
        const top = center.add(a.scale(half_height));
        const bot = center.sub(a.scale(half_height));
        self.ring(top, b.u, b.v, radius, color);
        self.ring(bot, b.u, b.v, radius, color);
        for ([_]math.Vec3{ b.u, b.u.scale(-1), b.v, b.v.scale(-1) }) |d| {
            self.line(bot.add(d.scale(radius)), top.add(d.scale(radius)), color);
        }
        self.arc(top, a, b.u, radius, color);
        self.arc(top, a, b.v, radius, color);
        self.arc(bot, a.scale(-1), b.u, radius, color);
        self.arc(bot, a.scale(-1), b.v, radius, color);
    }

    /// Infinite-plane marker: a `size`-wide square plus the normal.
    pub fn plane(self: *DebugDraw, point: math.Vec3, normal: math.Vec3, size: f32, color: math.Vec3) void {
        const b = basis(normal);
        const h = size * 0.5;
        const c0 = point.add(b.u.scale(-h)).add(b.v.scale(-h));
        const c1 = point.add(b.u.scale(h)).add(b.v.scale(-h));
        const c2 = point.add(b.u.scale(h)).add(b.v.scale(h));
        const c3 = point.add(b.u.scale(-h)).add(b.v.scale(h));
        self.line(c0, c1, color);
        self.line(c1, c2, color);
        self.line(c2, c3, color);
        self.line(c3, c0, color);
        self.line(point, point.add(normal.normalize().scale(h * 0.5)), color);
    }

    pub fn flush(self: *DebugDraw, ctx: *const Context, cmd: vk.CommandBuffer, view_proj: math.Mat4) !void {
        if (self.count == 0) return;
        const bytes: vk.DeviceSize = @sizeOf(LineVertex) * self.count;
        const mapped = try ctx.device.mapMemory(self.buffer.memory, 0, bytes, .{});
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..bytes], std.mem.sliceAsBytes(self.verts[0..self.count]));
        ctx.device.unmapMemory(self.buffer.memory);

        ctx.device.cmdBindPipeline(cmd, .graphics, self.pipeline.handle);
        ctx.device.cmdPushConstants(cmd, self.pipeline.layout, .{ .vertex = true }, 0, @sizeOf(math.Mat4), &view_proj);
        ctx.device.cmdBindVertexBuffers(cmd, 0, &.{self.buffer.handle}, &.{0});
        ctx.device.cmdDraw(cmd, self.count, 1, 0, 0);
        self.count = 0;
    }
};

const unit_x = math.Vec3{ .x = 1, .y = 0, .z = 0 };
const unit_y = math.Vec3{ .x = 0, .y = 1, .z = 0 };
const unit_z = math.Vec3{ .x = 0, .y = 0, .z = 1 };

/// Two unit vectors perpendicular to `axis` (and each other).
fn basis(axis: math.Vec3) struct { u: math.Vec3, v: math.Vec3 } {
    const a = axis.normalize();
    const ref = if (@abs(a.y) < 0.99) unit_y else unit_x;
    const u = a.cross(ref).normalize();
    return .{ .u = u, .v = a.cross(u) };
}

test "aabb emits 12 edges and overflow is dropped" {
    var d = DebugDraw{ .pipeline = undefined, .buffer = undefined, .count = 0 };
    d.aabb(
        .{ .x = -1, .y = -1, .z = -1 },
        .{ .x = 1, .y = 1, .z = 1 },
        .{ .x = 1, .y = 1, .z = 1 },
    );
    try std.testing.expectEqual(@as(u32, 24), d.count);
    d.count = max_verts;
    d.line(
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
    );
    try std.testing.expectEqual(@as(u32, max_verts), d.count);
}

test "obb with identity rotation matches aabb corners" {
    var d = DebugDraw{ .pipeline = undefined, .buffer = undefined, .count = 0 };
    d.obb(
        .{ .x = 0, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 0, .w = 1 },
        .{ .x = 1, .y = 1, .z = 1 },
        .{ .x = 0, .y = 1, .z = 1 },
    );
    try std.testing.expectEqual(@as(u32, 24), d.count);
    try std.testing.expectEqual(math.Vec3{ .x = -1, .y = -1, .z = -1 }, d.verts[0].pos);
    try std.testing.expectEqual(math.Vec3{ .x = 1, .y = -1, .z = -1 }, d.verts[1].pos);
}

test "shape gizmos emit even line counts" {
    var d = DebugDraw{ .pipeline = undefined, .buffer = undefined, .count = 0 };
    d.sphere(.{ .x = 0, .y = 0, .z = 0 }, 1, unit_x);
    try std.testing.expectEqual(@as(u32, 3 * 20 * 2), d.count);

    d.count = 0;
    d.cylinder(.{ .x = 0, .y = 0, .z = 0 }, unit_y, 1, 1, unit_x);
    try std.testing.expectEqual(@as(u32, (2 * 20 + 4) * 2), d.count);

    d.count = 0;
    d.capsule(.{ .x = 0, .y = 0, .z = 0 }, unit_y, 1, 1, unit_x);
    try std.testing.expectEqual(@as(u32, (2 * 20 + 4 + 4 * 8) * 2), d.count);

    d.count = 0;
    d.plane(.{ .x = 0, .y = 0, .z = 0 }, unit_y, 10, unit_x);
    try std.testing.expectEqual(@as(u32, 5 * 2), d.count);
}
