const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
const Context = @import("vk/context.zig").Context;
const Swapchain = @import("vk/swapchain.zig").Swapchain;
const pipeline_mod = @import("vk/pipeline.zig");
const Pipeline = pipeline_mod.Pipeline;
const Buffer = @import("vk/buffer.zig").Buffer;
const mesh = @import("mesh.zig");
const math = @import("../math.zig");

const max_frames_in_flight: u32 = 2;

// Vertex layout + push constant for the mesh pipeline. pos at offset 0, normal
// after it; one 64-byte vertex-stage push constant for the MVP matrix.
const mesh_bindings = [_]vk.VertexInputBindingDescription{.{
    .binding = 0,
    .stride = @sizeOf(mesh.Vertex),
    .input_rate = .vertex,
}};
const mesh_attributes = [_]vk.VertexInputAttributeDescription{
    .{ .location = 0, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(mesh.Vertex, "pos") },
    .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(mesh.Vertex, "normal") },
};
const mesh_push = [_]vk.PushConstantRange{.{
    .stage_flags = .{ .vertex_bit = true },
    .offset = 0,
    .size = @sizeOf(math.Mat4),
}};
const mesh_config: pipeline_mod.Config = .{
    .bindings = &mesh_bindings,
    .attributes = &mesh_attributes,
    .push_constant_ranges = &mesh_push,
    .depth_test = true,
    .cull_back = true,
};

// Public surface for the rest of the engine: init/deinit, beginFrame/endFrame
// bracket a frame, reloadShaders is the shader-playground hot-reload hook.
// No vk.* type appears in any of these five signatures on purpose — that's
// what keeps the engine loop free of Vulkan, and is the seam a future backend
// swap would replace, if one is ever needed.
pub const MeshHandle = u32;
pub const ShaderHandle = u32;

const MeshEntry = struct {
    vertex_buffer: Buffer,
    index_buffer: Buffer,
    index_count: u32,
};

const ShaderEntry = struct {
    pipeline: Pipeline,
    vert_path: []const u8,
    frag_path: []const u8,
};

// Built-in shader paths. Callers use these with loadShader.
pub const shader = struct {
    pub const mesh_vert = "shaders/mesh.vert.spv";
    pub const lit_frag = "shaders/mesh.frag.spv";
    pub const flat_frag = "shaders/flat.frag.spv";
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    window: sdl.video.Window,

    ctx: Context,
    swapchain: Swapchain,

    // ponytail: ceiling 8 shaders. Grow when needed.
    shaders: [8]ShaderEntry = undefined,
    shader_count: u32 = 0,

    // ponytail: ceiling 64 meshes. ArrayList when needed.
    meshes: [64]MeshEntry = undefined,
    mesh_count: u32 = 0,

    command_pool: vk.CommandPool,
    command_buffers: [max_frames_in_flight]vk.CommandBuffer,

    image_available: []vk.Semaphore,
    // Per-swapchain-image, not per-frame: a binary semaphore signaled at present
    // must be unsignaled when reused, which only holds if it's keyed by image
    // index (VUID-vkQueueSubmit-pSignalSemaphores-00067).
    render_finished: []vk.Semaphore,
    in_flight: [max_frames_in_flight]vk.Fence,

    current_frame: u32,
    current_image_index: u32,
    framebuffer_resized: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;
        self.io = io;
        self.current_frame = 0;
        self.framebuffer_resized = false;
        self.shader_count = 0;
        self.mesh_count = 0;

        try sdl.init(.{ .video = true });
        errdefer sdl.shutdown();

        self.window = sdl.video.Window.init("Rhodo", 800, 600, .{ .vulkan = true, .resizable = true }) catch |err| {
            std.debug.print("Window.init failed: {}\n", .{err});
            return err;
        };
        errdefer self.window.deinit();
        _ = sdl.c.SDL_ShowWindow(self.window.value);

        self.ctx = try Context.init(allocator, self.window);
        errdefer self.ctx.deinit();

        self.swapchain = try Swapchain.init(&self.ctx, self.window);
        errdefer self.swapchain.deinit(&self.ctx);

        _ = try self.loadShader(shader.mesh_vert, shader.lit_frag);
        errdefer for (self.shaders[0..self.shader_count]) |*s| s.pipeline.deinit(&self.ctx);

        try self.swapchain.buildFramebuffers(&self.ctx, self.shaders[0].pipeline.render_pass);

        try self.createCommandPool();
        try self.createCommandBuffers();
        errdefer self.ctx.device.destroyCommandPool(self.command_pool, null);

        try self.createSyncObjects();

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.ctx.device.deviceWaitIdle() catch {};

        for (self.image_available) |s| self.ctx.device.destroySemaphore(s, null);
        self.allocator.free(self.image_available);
        for (self.render_finished) |s| self.ctx.device.destroySemaphore(s, null);
        self.allocator.free(self.render_finished);
        for (0..max_frames_in_flight) |i| {
            self.ctx.device.destroyFence(self.in_flight[i], null);
        }
        self.ctx.device.destroyCommandPool(self.command_pool, null);

        for (self.meshes[0..self.mesh_count]) |*entry| {
            entry.vertex_buffer.deinit(&self.ctx);
            entry.index_buffer.deinit(&self.ctx);
        }
        for (self.shaders[0..self.shader_count]) |*s| s.pipeline.deinit(&self.ctx);
        self.swapchain.deinit(&self.ctx);
        self.ctx.deinit();

        self.window.deinit();
        sdl.quit(.{ .video = true });
        sdl.shutdown();
    }

    // Acquire the next image, wait/reset the in-flight fence, and begin
    // recording. Handles OutOfDateKHR by recreating the swapchain and retrying
    // once. Call draw commands between beginFrame and endFrame.
    pub fn beginFrame(self: *Renderer) !void {
        const f = self.current_frame;
        _ = try self.ctx.device.waitForFences(&.{self.in_flight[f]}, .true, std.math.maxInt(u64));

        const acquire_semaphore = self.image_available[f % self.image_available.len];
        const acquired = self.ctx.device.acquireNextImageKHR(
            self.swapchain.handle,
            std.math.maxInt(u64),
            acquire_semaphore,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                try self.swapchain.recreate(&self.ctx, self.window, self.shaders[0].pipeline.render_pass);
                return self.beginFrame();
            },
            else => return err,
        };
        if (acquired.result == .suboptimal_khr) self.framebuffer_resized = true;
        self.current_image_index = acquired.image_index;

        try self.ctx.device.resetFences(&.{self.in_flight[f]});

        const cmd = self.command_buffers[f];
        try self.ctx.device.resetCommandBuffer(cmd, .{});
        try self.ctx.device.beginCommandBuffer(cmd, &.{});

        self.ctx.device.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.swapchain.extent.width),
            .height = @floatFromInt(self.swapchain.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        }});
        self.ctx.device.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{.{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain.extent,
        }});

        const clears = [_]vk.ClearValue{
            .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
            .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
        };
        self.ctx.device.cmdBeginRenderPass(cmd, &.{
            .render_pass = self.shaders[0].pipeline.render_pass,
            .framebuffer = self.swapchain.framebuffers[self.current_image_index],
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain.extent },
            .clear_value_count = clears.len,
            .p_clear_values = &clears,
        }, .@"inline");
    }

    // End the render pass, submit, and present. Handles OutOfDateKHR / resize
    // by recreating the swapchain after presenting.
    pub fn endFrame(self: *Renderer) !void {
        const f = self.current_frame;
        const cmd = self.command_buffers[f];

        self.ctx.device.cmdEndRenderPass(cmd);
        try self.ctx.device.endCommandBuffer(cmd);

        const image_index = self.current_image_index;
        const acquire_semaphore = self.image_available[f % self.image_available.len];
        const wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output_bit = true };
        try self.ctx.device.queueSubmit(self.ctx.graphics_queue, &.{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{acquire_semaphore},
            .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmd},
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&self.render_finished[image_index]),
        }}, self.in_flight[f]);

        // ponytail: not catching OutOfDateKHR here. Acquire already catches it
        // on the next frame, so a plain try keeps one resize path instead of two
        // (matches vulkan-zig's reference Swapchain.present).
        _ = try self.ctx.device.queuePresentKHR(self.ctx.present_queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished[image_index]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain.handle),
            .p_image_indices = @ptrCast(&image_index),
        });

        if (self.framebuffer_resized) {
            self.framebuffer_resized = false;
            try self.swapchain.recreate(&self.ctx, self.window, self.shaders[0].pipeline.render_pass);
        }

        self.current_frame = (f + 1) % max_frames_in_flight;
    }

    // Call when the window resize event fires. Actual swapchain rebuild happens
    // lazily at the next beginFrame/endFrame via OutOfDateKHR / this flag, not
    // synchronously here, so this is just a notification.
    pub fn notifyResized(self: *Renderer) void {
        self.framebuffer_resized = true;
    }

    // Minimal event surface so sandbox/main.zig can drive its own loop without
    // importing sdl3 — same reason vk.* types don't cross this file's public
    // API. Add variants here as the engine needs them (key press, mouse, etc);
    // this is deliberately not a 1:1 mirror of sdl.events.Event.
    pub const Event = union(enum) {
        quit,
        resized,
    };

    // ponytail: Escape-quits-the-app is baked in here as a placeholder. That's
    // input policy, which belongs in game code, not the render/window layer —
    // upgrade path is dropping the key_down case here and adding a real input
    // event (e.g. .key_down: KeyCode) once you have an input system to hand it to.
    pub fn pollEvent(self: *Renderer) ?Event {
        _ = self;
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => return .quit,
                .window_resized => return .resized,
                .key_down => |k| if (k.key == .escape) return .quit,
                else => continue,
            }
        }
        return null;
    }

    // Shader playground hot-reload entry point. Rebuilds just the pipeline from
    // new shader source; if the new shaders fail to compile, the old pipeline
    // keeps running and the error is returned to the caller to report.
    pub fn reloadShaders(self: *Renderer, vert_path: []const u8, frag_path: []const u8) !void {
        // ponytail: reload shader 0 only. Per-handle reload when shader playground needs it.
        try self.shaders[0].pipeline.reload(&self.ctx, self.io, vert_path, frag_path);
        self.shaders[0].vert_path = vert_path;
        self.shaders[0].frag_path = frag_path;
    }

    pub fn loadShader(self: *Renderer, vert_path: []const u8, frag_path: []const u8) !ShaderHandle {
        const handle: ShaderHandle = self.shader_count;
        self.shaders[handle] = .{
            .pipeline = try Pipeline.init(&self.ctx, self.io, self.swapchain.format, vert_path, frag_path, mesh_config),
            .vert_path = vert_path,
            .frag_path = frag_path,
        };
        self.shader_count += 1;
        return handle;
    }

    pub fn uploadMesh(self: *Renderer, m: mesh.Mesh) !MeshHandle {
        defer m.deinit(self.allocator);

        const handle: MeshHandle = self.mesh_count;
        self.meshes[handle] = .{
            .vertex_buffer = try Buffer.hostVisibleWith(&self.ctx, .{ .vertex_buffer_bit = true }, mesh.Vertex, m.vertices),
            .index_buffer = try Buffer.hostVisibleWith(&self.ctx, .{ .index_buffer_bit = true }, u32, m.indices),
            .index_count = @intCast(m.indices.len),
        };
        self.mesh_count += 1;
        return handle;
    }

    // ponytail: immediate-mode, no draw list. Pipeline bound per-call.
    // Upgrade: sort by pipeline when you have many draw calls.
    pub fn drawMesh(self: *Renderer, sh: ShaderHandle, handle: MeshHandle, transform: math.Mat4) void {
        const cmd = self.command_buffers[self.current_frame];
        const entry = self.meshes[handle];
        const pipeline = self.shaders[sh].pipeline;

        self.ctx.device.cmdBindPipeline(cmd, .graphics, pipeline.handle);

        const aspect = @as(f32, @floatFromInt(self.swapchain.extent.width)) /
            @as(f32, @floatFromInt(self.swapchain.extent.height));
        const view = math.Mat4.lookAt(
            .{ .x = 0, .y = 0, .z = 4 },
            .{ .x = 0, .y = 0, .z = 0 },
            .{ .x = 0, .y = 1, .z = 0 },
        );
        const proj = math.Mat4.perspective(std.math.pi / 4.0, aspect, 0.1, 100.0);
        const mvp = proj.mul(view).mul(transform);

        self.ctx.device.cmdPushConstants(cmd, pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(math.Mat4), &mvp);
        self.ctx.device.cmdBindVertexBuffers(cmd, 0, &.{entry.vertex_buffer.handle}, &.{0});
        self.ctx.device.cmdBindIndexBuffer(cmd, entry.index_buffer.handle, 0, .uint32);
        self.ctx.device.cmdDrawIndexed(cmd, entry.index_count, 1, 0, 0, 0);
    }

    fn createCommandPool(self: *Renderer) !void {
        self.command_pool = try self.ctx.device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.ctx.queue_families.graphics,
        }, null);
    }

    fn createCommandBuffers(self: *Renderer) !void {
        try self.ctx.device.allocateCommandBuffers(&.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = max_frames_in_flight,
        }, &self.command_buffers);
    }

    fn createSyncObjects(self: *Renderer) !void {
        self.image_available = try self.allocator.alloc(vk.Semaphore, self.swapchain.images.len);
        for (self.image_available) |*s| s.* = try self.ctx.device.createSemaphore(&.{}, null);
        self.render_finished = try self.allocator.alloc(vk.Semaphore, self.swapchain.images.len);
        for (self.render_finished) |*s| s.* = try self.ctx.device.createSemaphore(&.{}, null);
        for (0..max_frames_in_flight) |i| {
            self.in_flight[i] = try self.ctx.device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        }
    }
};
