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
const Camera = @import("../camera.zig").Camera;
const DebugDraw = @import("debug.zig").DebugDraw;
const texture_mod = @import("texture.zig");

const max_frames_in_flight: u32 = 2;
// ponytail: ceiling 32 textures, one descriptor set each. Bigger pool when needed.
const max_textures: u32 = 32;

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
// bracket a frame, pollShaderChanges is the shader-playground hot-reload hook.
// No vk.* type appears in any of these five signatures on purpose — that's
// what keeps the engine loop free of Vulkan, and is the seam a future backend
// swap would replace, if one is ever needed.
pub const MeshHandle = u32;
pub const ShaderHandle = u32;
pub const TextureHandle = u32;

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
    .stage_flags = .{ .vertex_bit = true },
    .offset = 0,
    .size = @sizeOf(math.Mat4),
}};

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
    pub const sprite_vert = "shaders/sprite.vert.spv";
    pub const sprite_frag = "shaders/sprite.frag.spv";
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

    // Single gamepad slot (SDL's gamepad_added for a pre-connected pad arrives
    // during init, so a DualShock is picked up automatically).
    // ponytail: one pad only; multi-controller when a game needs player 2.
    gamepad: ?sdl.gamepad.Gamepad = null,
    gamepad_id: ?sdl.joystick.Id = null,

    // Bound once per frame via setCamera; folded into each draw's MVP.
    camera: Camera = .{},

    // CPU line list, flushed automatically at endFrame (depth off, drawn last).
    debug: DebugDraw,

    watched: [8]WatchEntry = undefined,
    watched_count: u32 = 0,

    // Sprites: one combined-image-sampler descriptor per texture, one shared
    // unit quad + pipeline (blend on, depth off). One draw call per sprite.
    tex_layout: vk.DescriptorSetLayout,
    tex_layouts: [1]vk.DescriptorSetLayout = undefined,
    tex_pool: vk.DescriptorPool,
    textures: [max_textures]TextureEntry = undefined,
    texture_count: u32 = 0,
    sprite_pipeline: Pipeline,
    quad_vb: Buffer,
    quad_ib: Buffer,

    // Shader hot-reload watch list. Every pipeline (loadShader, debug lines,
    // sprites) registers its .spv sources; pollShaderChanges() stats them once
    // per frame and rebuilds dirty pipelines in place. Targets are tags, not
    // pointers — Renderer is returned by value from init, so stored pointers
    // would dangle; these resolve against the live self.
    // ponytail: fixed 8 slots. Grow when you load more shaders.
    const WatchTarget = union(enum) { shader: ShaderHandle, debug, sprite };
    const WatchEntry = struct {
        target: WatchTarget,
        vert_path: []const u8,
        frag_path: []const u8,
        vert_mtime: std.Io.Timestamp,
        frag_mtime: std.Io.Timestamp,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Renderer {
        var self: Renderer = undefined;
        self.allocator = allocator;
        self.io = io;
        self.current_frame = 0;
        self.framebuffer_resized = false;
        self.camera = .{};
        self.watched_count = 0;
        self.gamepad = null;
        self.gamepad_id = null;
        self.shader_count = 0;
        self.mesh_count = 0;

        // HIDAPI's hidraw scan SIGILLs on some Linux boxes (bad backend fn pointer
        // during enumeration) and kills the app before the window exists. Disable
        // it; the evdev driver still exposes standard gamepads (sticks/buttons).
        // ponytail: re-enable if you ever need HIDAPI-only features (gyro, lightbar).
        try sdl.hints.set(.joystick_hidapi, "0");
        try sdl.init(.{ .video = true, .gamepad = true });
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

        self.debug = try DebugDraw.init(&self.ctx, self.io, self.swapchain.format);
        errdefer self.debug.deinit(&self.ctx);
        self.watch(.debug, DebugDraw.vert_path, DebugDraw.frag_path);

        self.tex_layout = try self.ctx.device.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = &.{
                .{
                    .binding = 0,
                    .descriptor_type = .combined_image_sampler,
                    .descriptor_count = 1,
                    .stage_flags = .{ .fragment_bit = true },
                },
            },
        }, null);
        errdefer self.ctx.device.destroyDescriptorSetLayout(self.tex_layout, null);
        self.tex_layouts = .{self.tex_layout};
        self.tex_pool = try self.ctx.device.createDescriptorPool(&.{
            .max_sets = max_textures,
            .pool_size_count = 1,
            .p_pool_sizes = &.{
                .{ .type = .combined_image_sampler, .descriptor_count = max_textures },
            },
        }, null);
        errdefer self.ctx.device.destroyDescriptorPool(self.tex_pool, null);
        self.texture_count = 0;
        self.sprite_pipeline = try Pipeline.init(&self.ctx, self.io, self.swapchain.format, shader.sprite_vert, shader.sprite_frag, .{
            .bindings = &sprite_bindings,
            .attributes = &sprite_attributes,
            .set_layouts = &self.tex_layouts,
            .push_constant_ranges = &sprite_push,
            .blend = true,
        });
        errdefer self.sprite_pipeline.deinit(&self.ctx);
        self.watch(.sprite, shader.sprite_vert, shader.sprite_frag);
        self.quad_vb = try Buffer.hostVisibleWith(&self.ctx, .{ .vertex_buffer_bit = true }, SpriteVertex, &quad_verts);
        errdefer self.quad_vb.deinit(&self.ctx);
        self.quad_ib = try Buffer.hostVisibleWith(&self.ctx, .{ .index_buffer_bit = true }, u32, &quad_indices);
        errdefer self.quad_ib.deinit(&self.ctx);

        try self.swapchain.buildFramebuffers(&self.ctx, self.shaders[0].pipeline.render_pass);

        try self.createCommandPool();
        try self.createCommandBuffers();
        errdefer self.ctx.device.destroyCommandPool(self.command_pool, null);

        try self.createSyncObjects();

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.ctx.device.deviceWaitIdle() catch {};
        if (self.gamepad) |g| g.deinit();

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
        self.debug.deinit(&self.ctx);
        for (self.textures[0..self.texture_count]) |*e| e.tex.deinit(&self.ctx);
        self.ctx.device.destroyDescriptorPool(self.tex_pool, null);
        self.ctx.device.destroyDescriptorSetLayout(self.tex_layout, null);
        self.sprite_pipeline.deinit(&self.ctx);
        self.quad_vb.deinit(&self.ctx);
        self.quad_ib.deinit(&self.ctx);
        self.swapchain.deinit(&self.ctx);
        self.ctx.deinit();

        self.window.deinit();
        sdl.quit(.{ .video = true, .gamepad = true });
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

        try self.debug.flush(&self.ctx, cmd, self.viewProj());

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

    // Input codes the engine emits. Kept small on purpose: one variant per key
    // or button games bind today. ponytail: add a variant here + a case in the
    // matching keyCode()/padButtonCode()/axisCode() per new binding; mirror
    // SDL's full scancode/button sets only if you need free rebinding.
    pub const KeyCode = enum {
        // keyboard scancodes
        w, a, s, d, f, g, space, left_shift, escape,
        // gamepad buttons (SDL positional; PS4 = south:cross, east:circle, west:square, north:triangle)
        pad_south, pad_east, pad_west, pad_north,
        pad_dpad_up, pad_dpad_down, pad_dpad_left, pad_dpad_right,
        pad_l1, pad_r1,
        // gamepad axes
        axis_left_x, axis_left_y, axis_right_x, axis_right_y,
    };

    // Minimal event surface so sandbox/main.zig can drive its own loop without
    // importing sdl3 — same reason vk.* types don't cross this file's public
    // API. Add variants here as the engine needs them; this is deliberately not
    // a 1:1 mirror of sdl.events.Event.
    pub const Event = union(enum) {
        quit,
        resized,
        key_down: KeyCode,
        key_up: KeyCode,
        // Analog axis: sticks in [-1, 1], triggers in [0, 1].
        axis_motion: struct { axis: KeyCode, value: f32 },
        // Relative mouse delta in pixels. Only meaningful with capture on.
        mouse_motion: struct { dx: f32, dy: f32 },
    };

    // Translate SDL events into the engine's own input vocabulary so game code
    // never imports sdl3. Escape-to-quit is no longer policy here — the sandbox
    // decides what keys do.
    pub fn pollEvent(self: *Renderer) ?Event {
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit, .terminating => return .quit,
                .window_resized => return .resized,
                .key_down => |k| {
                    if (keyCode(k.scancode)) |code| return .{ .key_down = code };
                },
                .key_up => |k| {
                    if (keyCode(k.scancode)) |code| return .{ .key_up = code };
                },
                .mouse_motion => |m| return .{ .mouse_motion = .{ .dx = m.x_rel, .dy = m.y_rel } },
                .gamepad_added => |dev| self.openGamepad(dev.id),
                .gamepad_removed => |dev| self.closeGamepad(dev.id),
                .gamepad_axis_motion => |a| {
                    if (!self.isActivePad(a.id)) continue;
                    if (axisCode(a.axis)) |axis| return .{ .axis_motion = .{
                        .axis = axis,
                        .value = @as(f32, @floatFromInt(a.value)) / 32767.0,
                    } };
                },
                .gamepad_button_down => |b| {
                    if (!self.isActivePad(b.id)) continue;
                    if (padButtonCode(b.button)) |code| return .{ .key_down = code };
                },
                .gamepad_button_up => |b| {
                    if (!self.isActivePad(b.id)) continue;
                    if (padButtonCode(b.button)) |code| return .{ .key_up = code };
                },
                else => continue,
            }
        }
        return null;
    }

    // The slot holds one pad; events from any other connected pad are dropped
    // so a second controller can't drive the same game.
    fn isActivePad(self: *Renderer, id: sdl.joystick.Id) bool {
        const open = self.gamepad_id orelse return false;
        return open.value == id.value;
    }

    fn openGamepad(self: *Renderer, id: sdl.joystick.Id) void {
        if (self.gamepad != null) return;
        self.gamepad = sdl.gamepad.Gamepad.init(id) catch |err| {
            std.debug.print("Gamepad open failed: {}\n", .{err});
            return;
        };
        self.gamepad_id = id;
        if (self.gamepad.?.getName()) |name| {
            std.debug.print("Gamepad connected: {s}\n", .{name});
        } else |_| {}
    }

    fn closeGamepad(self: *Renderer, id: sdl.joystick.Id) void {
        if (!self.isActivePad(id)) return;
        self.gamepad.?.deinit();
        self.gamepad = null;
        self.gamepad_id = null;
    }

    fn keyCode(scancode: ?sdl.Scancode) ?KeyCode {
        return switch (scancode orelse return null) {
            .w => .w,
            .a => .a,
            .s => .s,
            .d => .d,
            .f => .f,
            .g => .g,
            .space => .space,
            .left_shift => .left_shift,
            .escape => .escape,
            else => null,
        };
    }

    fn axisCode(axis: sdl.gamepad.Axis) ?KeyCode {
        return switch (axis) {
            .left_x => .axis_left_x,
            .left_y => .axis_left_y,
            .right_x => .axis_right_x,
            .right_y => .axis_right_y,
            else => null,
        };
    }

    fn padButtonCode(button: sdl.gamepad.Button) ?KeyCode {
        return switch (button) {
            .south => .pad_south,
            .east => .pad_east,
            .west => .pad_west,
            .north => .pad_north,
            .dpad_up => .pad_dpad_up,
            .dpad_down => .pad_dpad_down,
            .dpad_left => .pad_dpad_left,
            .dpad_right => .pad_dpad_right,
            .left_shoulder => .pad_l1,
            .right_shoulder => .pad_r1,
            else => null,
        };
    }

    // Bind the camera for this frame's draws. The renderer folds its view/proj
    // into each MVP; game code never multiplies them itself.
    pub fn setCamera(self: *Renderer, cam: Camera) void {
        self.camera = cam;
    }

    // Toggle OS mouse capture: cursor hidden, relative motion only. Needed to
    // steer a mouse-look camera, and the escape hatch back to a normal cursor.
    pub fn setMouseCapture(self: *Renderer, enabled: bool) !void {
        return sdl.mouse.setWindowRelativeMode(self.window, enabled);
    }

    // Stat every watched shader file; rebuild pipelines whose sources changed.
    // deviceWaitIdle runs first (only on change frames) so a pipeline in use
    // by an in-flight frame isn't destroyed. Failures print once and keep the
    // old pipeline; the mtime still advances so it retries on the next save.
    pub fn pollShaderChanges(self: *Renderer) void {
        var any = false;
        for (self.watched[0..self.watched_count]) |*w| {
            if (mtimeOf(self.io, w.vert_path).nanoseconds != w.vert_mtime.nanoseconds or
                mtimeOf(self.io, w.frag_path).nanoseconds != w.frag_mtime.nanoseconds)
            {
                any = true;
                break;
            }
        }
        if (!any) return;
        self.ctx.device.deviceWaitIdle() catch {};
        for (self.watched[0..self.watched_count]) |*w| {
            const vm = mtimeOf(self.io, w.vert_path);
            const fm = mtimeOf(self.io, w.frag_path);
            if (vm.nanoseconds == w.vert_mtime.nanoseconds and fm.nanoseconds == w.frag_mtime.nanoseconds) continue;
            w.vert_mtime = vm;
            w.frag_mtime = fm;
            self.pipelineOf(w.target).reload(&self.ctx, self.io, w.vert_path, w.frag_path) catch |err| {
                std.debug.print("Shader reload failed for {s} / {s}: {}, keeping previous pipeline\n", .{ w.vert_path, w.frag_path, err });
            };
        }
    }

    fn pipelineOf(self: *Renderer, target: WatchTarget) *Pipeline {
        return switch (target) {
            .shader => |h| &self.shaders[h].pipeline,
            .debug => &self.debug.pipeline,
            .sprite => &self.sprite_pipeline,
        };
    }

    fn watch(self: *Renderer, target: WatchTarget, vert_path: []const u8, frag_path: []const u8) void {
        if (self.watched_count >= self.watched.len) return;
        self.watched[self.watched_count] = .{
            .target = target,
            .vert_path = vert_path,
            .frag_path = frag_path,
            .vert_mtime = mtimeOf(self.io, vert_path),
            .frag_mtime = mtimeOf(self.io, frag_path),
        };
        self.watched_count += 1;
    }

    fn mtimeOf(io: std.Io, path: []const u8) std.Io.Timestamp {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .nanoseconds = 0 };
        return stat.mtime;
    }

    pub fn loadShader(self: *Renderer, vert_path: []const u8, frag_path: []const u8) !ShaderHandle {
        const handle: ShaderHandle = self.shader_count;
        self.shaders[handle] = .{
            .pipeline = try Pipeline.init(&self.ctx, self.io, self.swapchain.format, vert_path, frag_path, mesh_config),
            .vert_path = vert_path,
            .frag_path = frag_path,
        };
        self.shader_count += 1;
        self.watch(.{ .shader = handle }, vert_path, frag_path);
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

        const mvp = self.viewProj().mul(transform);

        self.ctx.device.cmdPushConstants(cmd, pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(math.Mat4), &mvp);
        self.ctx.device.cmdBindVertexBuffers(cmd, 0, &.{entry.vertex_buffer.handle}, &.{0});
        self.ctx.device.cmdBindIndexBuffer(cmd, entry.index_buffer.handle, 0, .uint32);
        self.ctx.device.cmdDrawIndexed(cmd, entry.index_count, 1, 0, 0, 0);
    }

    // Fire-and-forget debug lines in world space, flushed automatically at
    // endFrame (depth off, drawn last so always visible).
    pub fn drawLine(self: *Renderer, a: math.Vec3, b: math.Vec3, color: math.Vec3) void {
        self.debug.line(a, b, color);
    }

    pub fn drawAabb(self: *Renderer, min: math.Vec3, max: math.Vec3, color: math.Vec3) void {
        self.debug.aabb(min, max, color);
    }

    pub fn drawObb(self: *Renderer, pos: math.Vec3, rot: math.Vec4, half: math.Vec3, color: math.Vec3) void {
        self.debug.obb(pos, rot, half, color);
    }

    // Upload an RGBA image as a sampled texture. One descriptor set per
    // texture, drawn with drawSprite (blend on, depth off, screen space).
    pub fn loadTexture(self: *Renderer, path: [:0]const u8) !TextureHandle {
        if (self.texture_count >= max_textures) return error.TooManyTextures;
        const handle: TextureHandle = self.texture_count;

        const tex = try texture_mod.load(&self.ctx, self.command_pool, path);
        errdefer tex.deinit(&self.ctx);

        var sets: [1]vk.DescriptorSet = undefined;
        try self.ctx.device.allocateDescriptorSets(&.{
            .descriptor_pool = self.tex_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &self.tex_layouts,
        }, &sets);

        const img_info = vk.DescriptorImageInfo{
            .sampler = tex.sampler,
            .image_view = tex.view,
            .image_layout = .shader_read_only_optimal,
        };
        // Unused descriptor kinds still need a pointer; never dereferenced for
        // a combined image sampler write.
        const dummy_buf = std.mem.zeroes(vk.DescriptorBufferInfo);
        const dummy_view: vk.BufferView = .null_handle;
        self.ctx.device.updateDescriptorSets(&.{.{
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
    // top-left). One draw call per sprite, no batching.
    // ponytail: no batching until draw calls hurt.
    pub fn drawSprite(self: *Renderer, tex: TextureHandle, transform: math.Mat4) void {
        const cmd = self.command_buffers[self.current_frame];
        const entry = self.textures[tex];

        self.ctx.device.cmdBindPipeline(cmd, .graphics, self.sprite_pipeline.handle);
        self.ctx.device.cmdBindDescriptorSets(cmd, .graphics, self.sprite_pipeline.layout, 0, &.{entry.set}, null);

        const w: f32 = @floatFromInt(self.swapchain.extent.width);
        const h: f32 = @floatFromInt(self.swapchain.extent.height);
        const mvp = math.Mat4.orthographic(0, w, h, 0, -1, 1).mul(transform);

        self.ctx.device.cmdPushConstants(cmd, self.sprite_pipeline.layout, .{ .vertex_bit = true }, 0, @sizeOf(math.Mat4), &mvp);
        self.ctx.device.cmdBindVertexBuffers(cmd, 0, &.{self.quad_vb.handle}, &.{0});
        self.ctx.device.cmdBindIndexBuffer(cmd, self.quad_ib.handle, 0, .uint32);
        self.ctx.device.cmdDrawIndexed(cmd, quad_indices.len, 1, 0, 0, 0);
    }

    fn viewProj(self: *Renderer) math.Mat4 {
        const aspect = @as(f32, @floatFromInt(self.swapchain.extent.width)) /
            @as(f32, @floatFromInt(self.swapchain.extent.height));
        return self.camera.projection(aspect).mul(self.camera.view());
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
