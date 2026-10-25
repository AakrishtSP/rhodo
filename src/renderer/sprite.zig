const std = @import("std");
const vk = @import("vulkan");
const Context = @import("vk/context.zig").Context;
const pipeline_mod = @import("vk/pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const Buffer = @import("vk/buffer.zig").Buffer;
const texture_mod = @import("texture.zig");
const math = @import("../math.zig");

pub const TextureHandle = u32;

// ponytail: ceiling 32 textures, one descriptor set each. Bigger pool when needed.
const max_textures: u32 = 32;

const TextureEntry = struct {
    tex: texture_mod.Texture,
    set: vk.DescriptorSet,
};

const SpriteVertex = struct { pos: math.Vec3, uv: [2]f32 };

// Unit quad, centered, UV origin top-left to match stb_image row order.
const quad_verts = [_]SpriteVertex{
    .{ .pos = .{ .x = -0.5, .y = -0.5, .z = 0 }, .uv = .{ 0, 0 } },
    .{ .pos = .{ .x = 0.5, .y = -0.5, .z = 0 }, .uv = .{ 1, 0 } },
    .{ .pos = .{ .x = 0.5, .y = 0.5, .z = 0 }, .uv = .{ 1, 1 } },
    .{ .pos = .{ .x = -0.5, .y = 0.5, .z = 0 }, .uv = .{ 0, 1 } },
};
const quad_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };

const sprite_bindings = [_]vk.VertexInputBindingDescription{.{
    .binding = 0,
    .stride = @sizeOf(SpriteVertex),
    .input_rate = .vertex,
}};
const sprite_attributes = [_]vk.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(SpriteVertex, "pos") },
    .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(SpriteVertex, "uv") },
};
const sprite_push = [_]vk.PushConstantRange{.{
    .stage_flags = .{ .vertex = true },
    .offset = 0,
    .size = @sizeOf(math.Mat4),
}};

// Textured-quad system: texture registry (one descriptor set each), shared
// unit quad + blend-on/depth-off pipeline. One draw call per sprite.
// ponytail: no batching until draw calls hurt.
pub const Sprites = struct {
    allocator: std.mem.Allocator,
    tex_layout: vk.DescriptorSetLayout,
    // Heap-boxed so pipeline.config's slice survives struct copies (Renderer
    // is returned by value; a field slice would dangle).
    tex_layouts: *[1]vk.DescriptorSetLayout,
    tex_pool: vk.DescriptorPool,
    textures: [max_textures]TextureEntry = undefined,
    texture_count: u32 = 0,
    pipeline: Pipeline,
    quad_vb: Buffer,
    quad_ib: Buffer,

    pub fn init(allocator: std.mem.Allocator, ctx: *const Context, io: std.Io, format: vk.Format) !Sprites {
        var self: Sprites = undefined;
        self.allocator = allocator;
        self.tex_layout = try ctx.device.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = &.{
                .{
                    .binding = 0,
                    .descriptor_type = .combined_image_sampler,
                    .descriptor_count = 1,
                    .stage_flags = .{ .fragment = true },
                },
            },
        }, null);
        errdefer ctx.device.destroyDescriptorSetLayout(self.tex_layout, null);
        self.tex_layouts = try allocator.create([1]vk.DescriptorSetLayout);
        errdefer allocator.destroy(self.tex_layouts);
        self.tex_layouts.* = .{self.tex_layout};
        self.tex_pool = try ctx.device.createDescriptorPool(&.{
            .max_sets = max_textures,
            .pool_size_count = 1,
            .p_pool_sizes = &.{
                .{ .type = .combined_image_sampler, .descriptor_count = max_textures },
            },
        }, null);
        errdefer ctx.device.destroyDescriptorPool(self.tex_pool, null);
        self.texture_count = 0;
        self.pipeline = try Pipeline.init(ctx, io, format, "shaders/sprite.vert.spv", "shaders/sprite.frag.spv", .{
            .bindings = &sprite_bindings,
            .attributes = &sprite_attributes,
            .set_layouts = self.tex_layouts,
            .push_constant_ranges = &sprite_push,
            .blend = true,
        });
        errdefer self.pipeline.deinit(ctx);
        self.quad_vb = try Buffer.hostVisibleWith(ctx, .{ .vertex_buffer = true }, SpriteVertex, &quad_verts);
        errdefer self.quad_vb.deinit(ctx);
        self.quad_ib = try Buffer.hostVisibleWith(ctx, .{ .index_buffer = true }, u32, &quad_indices);
        return self;
    }

    pub fn deinit(self: *Sprites, ctx: *const Context) void {
        for (self.textures[0..self.texture_count]) |*e| e.tex.deinit(ctx);
        self.quad_ib.deinit(ctx);
        self.quad_vb.deinit(ctx);
        self.pipeline.deinit(ctx);
        ctx.device.destroyDescriptorPool(self.tex_pool, null);
        ctx.device.destroyDescriptorSetLayout(self.tex_layout, null);
        self.allocator.destroy(self.tex_layouts);
    }

    pub fn loadTexture(self: *Sprites, ctx: *const Context, pool: vk.CommandPool, path: [:0]const u8) !TextureHandle {
        if (self.texture_count >= max_textures) return error.TooManyTextures;
        const handle: TextureHandle = self.texture_count;

        const tex = try texture_mod.load(ctx, pool, path);
        errdefer tex.deinit(ctx);

        var sets: [1]vk.DescriptorSet = undefined;
        try ctx.device.allocateDescriptorSets(&.{
            .descriptor_pool = self.tex_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = self.tex_layouts,
        }, &sets);

        const img_info = vk.DescriptorImageInfo{
            .sampler = tex.sampler,
            .image_view = tex.view,
            .image_layout = .shader_read_only_optimal,
        };
        // Unused descriptor kinds still need a pointer; never dereferenced for
        // a combined image sampler write.
        const dummy_buf = std.mem.zeroes(vk.DescriptorBufferInfo);
        const dummy_view: vk.BufferView = .null;
        ctx.device.updateDescriptorSets(&.{.{
            .dst_set = sets[0],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = @ptrCast(&img_info),
            .p_buffer_info = @ptrCast(&dummy_buf),
            .p_texel_buffer_view = @ptrCast(&dummy_view),
        }}, null);

        self.textures[handle] = .{ .tex = tex, .set = sets[0] };
        self.texture_count += 1;
        return handle;
    }

    // Screen-space sprite: transform maps the unit quad to pixels (origin
    // top-left). Extent sizes the orthographic projection.
    pub fn draw(self: *Sprites, ctx: *const Context, cmd: vk.CommandBuffer, extent: vk.Extent2D, tex: TextureHandle, transform: math.Mat4) void {
        const entry = self.textures[tex];
        ctx.device.cmdBindPipeline(cmd, .graphics, self.pipeline.handle);
        ctx.device.cmdBindDescriptorSets(cmd, .graphics, self.pipeline.layout, 0, &.{entry.set}, null);

        const w: f32 = @floatFromInt(extent.width);
        const h: f32 = @floatFromInt(extent.height);
        const mvp = math.Mat4.orthographic(0, w, h, 0, -1, 1).mul(transform);

        ctx.device.cmdPushConstants(cmd, self.pipeline.layout, .{ .vertex = true }, 0, @sizeOf(math.Mat4), &mvp);
        ctx.device.cmdBindVertexBuffers(cmd, 0, &.{self.quad_vb.handle}, &.{0});
        ctx.device.cmdBindIndexBuffer(cmd, self.quad_ib.handle, 0, .uint32);
        ctx.device.cmdDrawIndexed(cmd, quad_indices.len, 1, 0, 0, 0);
    }
};
