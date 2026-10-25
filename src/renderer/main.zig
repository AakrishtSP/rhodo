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
const physics = @import("../physics.zig");
const Camera = @import("../camera.zig").Camera;
const DebugDraw = @import("debug.zig").DebugDraw;
const imgui = @import("../imgui.zig").imgui;
const Sprites = @import("sprite.zig").Sprites;

// Vulkan loader for ImGui's NO_PROTOTYPES backend. Resolves through our
// instance proc addr (which also returns device functions).
var ui_loader_proc: ?vk.PfnGetInstanceProcAddr = null;
var ui_loader_instance: vk.Instance = undefined;
fn uiVkLoader(name: [*c]const u8, _: ?*anyopaque) callconv(.c) ?*const anyopaque {
    const p = ui_loader_proc orelse return null;
    return @ptrCast(p(ui_loader_instance, std.mem.span(name).ptr));
}

// Vk handles are enums or opaque pointers; ImGui takes void*.
fn vkToPtr(handle: anytype) ?*anyopaque {
    return switch (@typeInfo(@TypeOf(handle))) {
        .@"enum" => @ptrFromInt(@backingInt(handle)),
        .pointer => @ptrCast(handle),
        else => @compileError("vkToPtr expects a Vulkan handle"),
    };
}

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
    // 64B MVP + 16B tint + 16B light (dir xyz, ambient w). Vertex reads MVP,
    // fragment reads tint + light.
    .stage_flags = .{ .vertex = true, .fragment = true },
    .offset = 0,
    .size = @sizeOf(math.Mat4) + @sizeOf(math.Vec4) * 2,
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
pub const TextureHandle = @import("sprite.zig").TextureHandle;

// Data-oriented model: mesh + tint bundled once, drawn by value. Textures join
// here (UV pipeline + material.texture) when a textured glTF arrives;
// skeletal/keyframe runtime arrives with an animated glTF. Neither exists yet —
// physics + procedural motion cover all current movement.
pub const Model = struct { mesh: MeshHandle, color: math.Vec4 };

const LitPush = struct { mvp: math.Mat4, color: math.Vec4, light: math.Vec4 };

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

    // Bound once per frame via setCamera; folded into each draw's MVP.
    camera: Camera = .{},

    // Scene sun (direction to light + ambient), bound via setLight and folded
    // into lit draws like the camera. ponytail: one directional only; point
    // lights + fog arrive with atmosphere work, not before.
    light_dir: math.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    light_ambient: f32 = 0.2,

    // CPU line list, flushed automatically at endFrame (depth off, drawn last).
    debug: DebugDraw,

    watched: [8]WatchEntry = undefined,
    watched_count: u32 = 0,

    // Sprites: textured quads (own registry, pipeline, descriptor pool).
    sprites: Sprites,

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
        self.setLight(.{ .x = 0.5, .y = 0.8, .z = 0.6 }, 0.2);
        self.shader_count = 0;
        self.mesh_count = 0;

        // HIDAPI's hidraw scan SIGILLs on some Linux boxes (bad backend fn pointer
        // during enumeration) and kills the app before the window exists. Disable
        // it; the evdev driver still exposes standard gamepads (sticks/buttons).
        // ponytail: re-enable if you ever need HIDAPI-only features (gyro, lightbar).
        try sdl.hints.set(.joystick_hidapi, "0");
        try sdl.init(.{ .video = true, .gamepad = true, .audio = true });
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

        self.sprites = try Sprites.init(allocator, &self.ctx, self.io, self.swapchain.format);
        errdefer self.sprites.deinit(&self.ctx);
        self.watch(.sprite, shader.sprite_vert, shader.sprite_frag);

        try self.swapchain.buildFramebuffers(&self.ctx, self.shaders[0].pipeline.render_pass);

        try self.createCommandPool();
        try self.createCommandBuffers();
        errdefer self.ctx.device.destroyCommandPool(self.command_pool, null);

        try self.createSyncObjects();

        try self.initUi();
        errdefer self.shutdownUi();

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.ctx.device.deviceWaitIdle() catch {};
        self.shutdownUi();

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
        self.sprites.deinit(&self.ctx);
        self.swapchain.deinit(&self.ctx);
        self.ctx.deinit();

        self.window.deinit();
        sdl.quit(.{ .video = true, .gamepad = true, .audio = true });
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
            .null,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => {
                try self.recreateSwapchain();
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
        const wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output = true };
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
            try self.recreateSwapchain();
        }

        self.current_frame = (f + 1) % max_frames_in_flight;
    }

    // Call when the window resize event fires. Actual swapchain rebuild happens
    // lazily at the next beginFrame/endFrame via OutOfDateKHR / this flag, not
    // synchronously here, so this is just a notification.
    pub fn notifyResized(self: *Renderer) void {
        self.framebuffer_resized = true;
    }

    fn recreateSwapchain(self: *Renderer) !void {
        try self.swapchain.recreate(&self.ctx, self.window, self.shaders[0].pipeline.render_pass);
        imgui.Imgui_SetMinImageCount(@intCast(self.swapchain.images.len));
    }

    // Bind the camera for this frame's draws. The renderer folds its view/proj
    // into each MVP; game code never multiplies them itself.
    pub fn setCamera(self: *Renderer, cam: Camera) void {
        self.camera = cam;
    }

    // Bind the scene sun. Direction is normalized, ambient clamped 0..1.
    pub fn setLight(self: *Renderer, dir: math.Vec3, ambient: f32) void {
        const len = @sqrt(dir.dot(dir));
        if (len > 0) {
            self.light_dir = dir.scale(1.0 / len);
        }
        self.light_ambient = std.math.clamp(ambient, 0, 1);
    }

    // Toggle OS mouse capture: cursor hidden, relative motion only. Needed to
    // steer a mouse-look camera, and the escape hatch back to a normal cursor.
    pub fn setMouseCapture(self: *Renderer, enabled: bool) !void {
        return sdl.mouse.setWindowRelativeMode(self.window, enabled);
    }

    // Dear ImGui backend hookup (engine owns init/shutdown; the sandbox calls
    // rhodo.imgui directly). Reuses shaders[0]'s render pass + swapchain image
    // count; the backend creates its own descriptor pool (DescriptorPoolSize).
    pub fn initUi(self: *Renderer) !void {
        ui_loader_proc = @ptrCast(sdl.c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.NoVkGetInstanceProcAddr);
        ui_loader_instance = self.ctx.instance.handle;
        const ok = imgui.Imgui_Init(
            @ptrCast(self.window.value),
            vkToPtr(self.ctx.instance.handle),
            vkToPtr(self.ctx.physical_device),
            vkToPtr(self.ctx.device.handle),
            self.ctx.queue_families.graphics,
            vkToPtr(self.ctx.graphics_queue),
            vkToPtr(self.shaders[0].pipeline.render_pass),
            @intCast(self.swapchain.images.len),
            uiVkLoader,
            null,
        );
        if (!ok) return error.ImguiInitFailed;
    }

    pub fn shutdownUi(self: *Renderer) void {
        _ = self;
        imgui.Imgui_Shutdown();
    }

    // Begin a UI frame (call before sandbox UI code), end records it into cmd
    // (call after 3D draws, before endFrame — still inside the render pass).
    pub fn beginUi(self: *Renderer) void {
        _ = self;
        imgui.Imgui_NewFrame();
    }

    pub fn endUi(self: *Renderer) void {
        const cmd = self.command_buffers[self.current_frame];
        imgui.Imgui_Render(vkToPtr(cmd));
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
            .sprite => &self.sprites.pipeline,
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
            .vertex_buffer = try Buffer.hostVisibleWith(&self.ctx, .{ .vertex_buffer = true }, mesh.Vertex, m.vertices),
            .index_buffer = try Buffer.hostVisibleWith(&self.ctx, .{ .index_buffer = true }, u32, m.indices),
            .index_count = @intCast(m.indices.len),
        };
        self.mesh_count += 1;
        return handle;
    }

    /// Upload a mesh and pair it with a color — the one-call path for visuals.
    pub fn uploadModel(self: *Renderer, m: mesh.Mesh, color: math.Vec4) !Model {
        return .{ .mesh = try self.uploadMesh(m), .color = color };
    }

    // ponytail: immediate-mode, no draw list. Pipeline bound per-call.
    // Upgrade: sort by pipeline when you have many draw calls.
    pub fn drawMesh(self: *Renderer, sh: ShaderHandle, handle: MeshHandle, transform: math.Mat4) void {
        const cmd = self.command_buffers[self.current_frame];
        const entry = self.meshes[handle];
        const pipeline = self.shaders[sh].pipeline;

        self.ctx.device.cmdBindPipeline(cmd, .graphics, pipeline.handle);

        const mvp = self.viewProj().mul(transform);

        self.ctx.device.cmdPushConstants(cmd, pipeline.layout, .{ .vertex = true }, 0, @sizeOf(math.Mat4), &mvp);
        self.ctx.device.cmdBindVertexBuffers(cmd, 0, &.{entry.vertex_buffer.handle}, &.{0});
        self.ctx.device.cmdBindIndexBuffer(cmd, entry.index_buffer.handle, 0, .uint32);
        self.ctx.device.cmdDrawIndexed(cmd, entry.index_count, 1, 0, 0, 0);
    }

    // Lit + tinted via shader 0. drawMesh above stays for unlit/custom
    // pipelines (e.g. flat ground).
    pub fn drawMeshTinted(self: *Renderer, handle: MeshHandle, color: math.Vec4, transform: math.Mat4) void {
        const cmd = self.command_buffers[self.current_frame];
        const entry = self.meshes[handle];
        const pipeline = self.shaders[0].pipeline;

        self.ctx.device.cmdBindPipeline(cmd, .graphics, pipeline.handle);

        const push = LitPush{
            .mvp = self.viewProj().mul(transform),
            .color = color,
            .light = .{ .x = self.light_dir.x, .y = self.light_dir.y, .z = self.light_dir.z, .w = self.light_ambient },
        };
        self.ctx.device.cmdPushConstants(cmd, pipeline.layout, .{ .vertex = true, .fragment = true }, 0, @sizeOf(LitPush), &push);
        self.ctx.device.cmdBindVertexBuffers(cmd, 0, &.{entry.vertex_buffer.handle}, &.{0});
        self.ctx.device.cmdBindIndexBuffer(cmd, entry.index_buffer.handle, 0, .uint32);
        self.ctx.device.cmdDrawIndexed(cmd, entry.index_count, 1, 0, 0, 0);
    }

    pub fn drawModel(self: *Renderer, model: Model, transform: math.Mat4) void {
        self.drawMeshTinted(model.mesh, model.color, transform);
    }

    /// Draw a body's mesh at its synced transform (position/rotation/scale).
    pub fn drawBody(self: *Renderer, sim: *const physics.Physics, handle: physics.BodyHandle, model: Model) void {
        self.drawModel(model, math.Mat4.fromTransform(sim.transform(handle)));
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

    /// Character colliders are not bodies, so `drawColliders` can't see them.
    pub fn drawCapsule(self: *Renderer, pos: math.Vec3, axis: math.Vec3, radius: f32, half_height: f32, color: math.Vec3) void {
        self.debug.capsule(pos, axis, radius, half_height, color);
    }

    /// Debug: wireframe for every live collider, using the transforms from the
    /// last `sim.sync()`. Colors come from `Physics.setColor` (defaults by body
    /// type; triggers yellow). Colliders with no mesh show up only here.
    pub fn drawColliders(self: *Renderer, sim: *const physics.Physics) void {
        const up = math.Vec3{ .x = 0, .y = 1, .z = 0 };
        for (0..sim.count) |i| {
            const b = sim.bodies[i];
            if (!b.alive) continue;
            const t = physics.transforms[i];
            const c = math.Vec3{ .x = b.color.x, .y = b.color.y, .z = b.color.z };
            switch (b.kind) {
                .box => self.debug.obb(t.pos, t.rot, t.scale, c),
                .sphere => self.debug.sphere(t.pos, t.scale.x, c),
                // bounds are (r, h+r, r) for capsules and (r, h, r) for cylinders
                .capsule => self.debug.capsule(t.pos, up.rotateByQuat(t.rot), t.scale.x, t.scale.y - t.scale.x, c),
                .cylinder => self.debug.cylinder(t.pos, up.rotateByQuat(t.rot), t.scale.x, t.scale.y, c),
                .plane => self.debug.plane(t.pos, b.normal, 20, c),
            }
        }
    }

    // Upload an RGBA image as a sampled texture (delegates to Sprites).
    pub fn loadTexture(self: *Renderer, path: [:0]const u8) !TextureHandle {
        return self.sprites.loadTexture(&self.ctx, self.command_pool, path);
    }

    // Screen-space sprite: transform maps the unit quad to pixels (origin
    // top-left). One draw call per sprite, no batching.
    // ponytail: no batching until draw calls hurt.
    pub fn drawSprite(self: *Renderer, tex: TextureHandle, transform: math.Mat4) void {
        const cmd = self.command_buffers[self.current_frame];
        self.sprites.draw(&self.ctx, cmd, self.swapchain.extent, tex, transform);
    }

    fn viewProj(self: *Renderer) math.Mat4 {
        const aspect = @as(f32, @floatFromInt(self.swapchain.extent.width)) /
            @as(f32, @floatFromInt(self.swapchain.extent.height));
        return self.camera.projection(aspect).mul(self.camera.view());
    }

    fn createCommandPool(self: *Renderer) !void {
        self.command_pool = try self.ctx.device.createCommandPool(&.{
            .flags = .{ .reset_command_buffer = true },
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
            self.in_flight[i] = try self.ctx.device.createFence(&.{ .flags = .{ .signaled = true } }, null);
        }
    }
};
