const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

// A GPU buffer + its memory. Two constructors: hostVisible (CPU-mapped, used
// for vertex/index/staging) and deviceLocal (GPU-only, used for textures'
// staging target lives in texture.zig; this covers the buffer side).
// ponytail: host-visible vertex buffers skip the staging→device-local copy.
// Fine for static, modestly-sized meshes; upgrade to a staged device-local
// buffer if vertex bandwidth ever shows up in a profile.
pub const Buffer = struct {
    handle: vk.Buffer,
    memory: vk.DeviceMemory,
    size: vk.DeviceSize,

    pub fn deinit(self: Buffer, ctx: *const Context) void {
        ctx.device.destroyBuffer(self.handle, null);
        ctx.device.freeMemory(self.memory, null);
    }

    // Create a host-visible+coherent buffer and copy `data` into it.
    pub fn hostVisibleWith(ctx: *const Context, usage: vk.BufferUsageFlags, comptime T: type, data: []const T) !Buffer {
        const size: vk.DeviceSize = @sizeOf(T) * data.len;
        const self = try create(ctx, size, usage, .{ .host_visible_bit = true, .host_coherent_bit = true });
        const mapped = try ctx.device.mapMemory(self.memory, 0, size, .{});
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..size], std.mem.sliceAsBytes(data));
        ctx.device.unmapMemory(self.memory);
        return self;
    }

    pub fn create(ctx: *const Context, size: vk.DeviceSize, usage: vk.BufferUsageFlags, props: vk.MemoryPropertyFlags) !Buffer {
        const handle = try ctx.device.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        errdefer ctx.device.destroyBuffer(handle, null);

        const reqs = ctx.device.getBufferMemoryRequirements(handle);
        const memory = try ctx.device.allocateMemory(&.{
            .allocation_size = reqs.size,
            .memory_type_index = try findMemoryType(ctx, reqs.memory_type_bits, props),
        }, null);
        errdefer ctx.device.freeMemory(memory, null);

        try ctx.device.bindBufferMemory(handle, memory, 0);
        return .{ .handle = handle, .memory = memory, .size = size };
    }
};

pub fn findMemoryType(ctx: *const Context, type_bits: u32, props: vk.MemoryPropertyFlags) !u32 {
    const mem_props = ctx.instance.getPhysicalDeviceMemoryProperties(ctx.physical_device);
    for (0..mem_props.memory_type_count) |i| {
        const bit = @as(u32, 1) << @intCast(i);
        if (type_bits & bit != 0 and mem_props.memory_types[i].property_flags.contains(props)) {
            return @intCast(i);
        }
    }
    return error.NoSuitableMemoryType;
}

// One-shot command buffer for transfers/layout transitions (used by texture.zig).
// Allocates, records via the returned cmd, then submit+wait+free in end().
pub fn beginSingleTime(ctx: *const Context, pool: vk.CommandPool) !vk.CommandBuffer {
    var cmd: vk.CommandBuffer = undefined;
    try ctx.device.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd));
    try ctx.device.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
    return cmd;
}

pub fn endSingleTime(ctx: *const Context, pool: vk.CommandPool, cmd: vk.CommandBuffer) !void {
    try ctx.device.endCommandBuffer(cmd);
    try ctx.device.queueSubmit(ctx.graphics_queue, &.{.{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
    }}, .null_handle);
    try ctx.device.queueWaitIdle(ctx.graphics_queue);
    ctx.device.freeCommandBuffers(pool, 1, @ptrCast(&cmd));
}
