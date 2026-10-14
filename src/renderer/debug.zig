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
    .stage_flags = .{ .vertex_bit = true },
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

    pub fn init(ctx: *const Context, io: std.Io, format: vk.Format) !DebugDraw {
        return .{
            .pipeline = try Pipeline.init(ctx, io, format, "shaders/line.vert.spv", "shaders/line.frag.spv", line_config),
            .buffer = try Buffer.create(
                ctx,
                @sizeOf(LineVertex) * max_verts,
                .{ .vertex_buffer_bit = true },
                .{ .host_visible_bit = true, .host_coherent_bit = true },
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

    pub fn flush(self: *DebugDraw, ctx: *const Context, cmd: vk.CommandBuffer, view_proj: math.Mat4) !void {
        if (self.count == 0) return;
        const bytes: vk.DeviceSize = @sizeOf(LineVertex) * self.count;
        const mapped = try ctx.device.mapMemory(self.buffer.memory, 0, bytes, .{});
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..bytes], std.mem.sliceAsBytes(self.verts[0..self.count]));
        ctx.device.unmapMemory(self.buffer.memory);

        ctx.device.cmdBindPipeline(cmd, .graphics, self.pipeline.handle);
        ctx.device.cmdPushConstants(cmd, self.pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(math.Mat4), &view_proj);
        ctx.device.cmdBindVertexBuffers(cmd, 0, &.{self.buffer.handle}, &.{0});
        ctx.device.cmdDraw(cmd, self.count, 1, 0, 0);
        self.count = 0;
    }
};

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
