const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vk/context.zig").Context;
const buffer_mod = @import("vk/buffer.zig");
const Buffer = buffer_mod.Buffer;
const stb = @cImport({
    @cInclude("stb_image.h");
});

// RGBA pixels uploaded to a sampled, optimal-tiled VkImage. Load with load()
// (stb_image, forced to 4 channels, SRGB so sampled colors look right); free
// with deinit(). ponytail: no mipmaps — minification shimmers on small sprites;
// generate mipmaps when sprites scale down a lot.
pub const Texture = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    sampler: vk.Sampler,
    width: u32,
    height: u32,

    pub fn deinit(self: Texture, ctx: *const Context) void {
        ctx.device.destroySampler(self.sampler, null);
        ctx.device.destroyImageView(self.view, null);
        ctx.device.destroyImage(self.image, null);
        ctx.device.freeMemory(self.memory, null);
    }
};

pub fn load(ctx: *const Context, pool: vk.CommandPool, path: [:0]const u8) !Texture {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load(path.ptr, &w, &h, &channels, 4) orelse {
        std.debug.print("stbi_load({s}) failed: {s}\n", .{ path, std.mem.span(stb.stbi_failure_reason()) });
        return error.ImageLoadFailed;
    };
    defer stb.stbi_image_free(pixels);
    if (w <= 0 or h <= 0) return error.ImageEmpty;
    const width: u32 = @intCast(w);
    const height: u32 = @intCast(h);
    const byte_count: usize = @as(usize, width) * height * 4;

    const staging = try Buffer.hostVisibleWith(
        ctx,
        .{ .transfer_src_bit = true },
        u8,
        @as([*]u8, @ptrCast(pixels))[0..byte_count],
    );
    defer staging.deinit(ctx);

    const image = try ctx.device.createImage(&.{
        .image_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer ctx.device.destroyImage(image, null);

    const reqs = ctx.device.getImageMemoryRequirements(image);
    const memory = try ctx.device.allocateMemory(&.{
        .allocation_size = reqs.size,
        .memory_type_index = try buffer_mod.findMemoryType(ctx, reqs.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    errdefer ctx.device.freeMemory(memory, null);
    try ctx.device.bindImageMemory(image, memory, 0);

    const cmd = try buffer_mod.beginSingleTime(ctx, pool);
    transition(ctx, cmd, image, .undefined, .transfer_dst_optimal,
        .{}, .{ .transfer_write_bit = true },
        .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true });
    ctx.device.cmdCopyBufferToImage(cmd, staging.handle, image, .transfer_dst_optimal, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    }});
    transition(ctx, cmd, image, .transfer_dst_optimal, .shader_read_only_optimal,
        .{ .transfer_write_bit = true }, .{ .shader_read_bit = true },
        .{ .transfer_bit = true }, .{ .fragment_shader_bit = true });
    try buffer_mod.endSingleTime(ctx, pool, cmd);

    const view = try ctx.device.createImageView(&.{
        .image = image,
        .view_type = .@"2d",
        .format = .r8g8b8a8_srgb,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
    errdefer ctx.device.destroyImageView(view, null);

    const sampler = try ctx.device.createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .never,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = .false,
    }, null);

    return .{
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
    };
}

fn transition(
    ctx: *const Context,
    cmd: vk.CommandBuffer,
    image: vk.Image,
    old: vk.ImageLayout,
    new: vk.ImageLayout,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
) void {
    ctx.device.cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, null, null, &.{.{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old,
        .new_layout = new,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }});
}

// CPU-only: proves stb links and decodes, without touching the GPU.
test "stb decodes the test sprite as 64x64 RGBA" {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load("assets/sprite_test.png".ptr, &w, &h, &channels, 4) orelse return error.ImageLoadFailed;
    defer stb.stbi_image_free(pixels);
    try std.testing.expectEqual(@as(c_int, 64), w);
    try std.testing.expectEqual(@as(c_int, 64), h);
}
