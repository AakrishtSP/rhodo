const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;
const buffer = @import("buffer.zig");
const depth_format = @import("pipeline.zig").depth_format;

// Everything sized by the window: swapchain, its images/views, and the
// framebuffers built from them + a render pass. Destroyed and rebuilt wholesale
// on resize via recreate(); nothing here is mutated piecemeal.
pub const Swapchain = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    extent: vk.Extent2D,
    images: []vk.Image,
    image_views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,
    depth_image: vk.Image,
    depth_mem: vk.DeviceMemory,
    depth_view: vk.ImageView,

    // Builds the swapchain and image views only. Framebuffers need a render
    // pass, which the pipeline hasn't created yet at this point in startup —
    // call buildFramebuffers once Pipeline.init has run.
    pub fn init(ctx: *const Context, window: sdl.video.Window) !Swapchain {
        var self: Swapchain = undefined;
        self.handle = .null_handle;
        self.framebuffers = try ctx.allocator.alloc(vk.Framebuffer, 0);
        try self.create(ctx, window);
        try self.createImageViews(ctx);
        try self.createDepth(ctx);
        return self;
    }

    pub fn buildFramebuffers(self: *Swapchain, ctx: *const Context, render_pass: vk.RenderPass) !void {
        try self.createFramebuffers(ctx, render_pass);
    }

    pub fn deinit(self: *Swapchain, ctx: *const Context) void {
        self.cleanup(ctx);
        ctx.device.destroySwapchainKHR(self.handle, null);
    }

    // Waits for the device to go idle (frames in flight may still reference the
    // old framebuffers/views), tears down everything window-sized, and rebuilds
    // against the new window size. Blocks while the window is minimized (0x0)
    // rather than calling into Vulkan with an invalid extent.
    pub fn recreate(self: *Swapchain, ctx: *const Context, window: sdl.video.Window, render_pass: vk.RenderPass) !void {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = sdl.c.SDL_GetWindowSizeInPixels(window.value, &w, &h);
        while (w == 0 or h == 0) {
            try sdl.events.wait(); // ponytail: blocks the whole app while minimized; fine for a single window, revisit if you add background work
            _ = sdl.c.SDL_GetWindowSizeInPixels(window.value, &w, &h);
        }

        try ctx.device.deviceWaitIdle();

        // ponytail: destroy-then-create, not old_swapchain handoff. Handoff lets
        // the driver keep presenting retired images while the new chain spins up —
        // pointless here since deviceWaitIdle above means nothing is in flight.
        // Upgrade path: pass self.handle as old_swapchain and destroy it only
        // after the new one exists, if you ever drop the wait for faster resize.
        self.cleanup(ctx);
        ctx.device.destroySwapchainKHR(self.handle, null);
        self.handle = .null_handle;

        try self.create(ctx, window);
        try self.createImageViews(ctx);
        try self.createDepth(ctx);
        try self.createFramebuffers(ctx, render_pass);
    }

    fn cleanup(self: *Swapchain, ctx: *const Context) void {
        ctx.device.destroyImageView(self.depth_view, null);
        ctx.device.destroyImage(self.depth_image, null);
        ctx.device.freeMemory(self.depth_mem, null);
        for (self.framebuffers) |fb| ctx.device.destroyFramebuffer(fb, null);
        ctx.allocator.free(self.framebuffers);
        for (self.image_views) |iv| ctx.device.destroyImageView(iv, null);
        ctx.allocator.free(self.image_views);
        ctx.allocator.free(self.images);
    }

    // Depth attachment, sized to the swapchain extent. Rebuilt with the rest on
    // resize (it's extent-sized, like the framebuffers).
    fn createDepth(self: *Swapchain, ctx: *const Context) !void {
        self.depth_image = try ctx.device.createImage(&.{
            .image_type = .@"2d",
            .format = depth_format,
            .extent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = .{ .depth_stencil_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        const reqs = ctx.device.getImageMemoryRequirements(self.depth_image);
        self.depth_mem = try ctx.device.allocateMemory(&.{
            .allocation_size = reqs.size,
            .memory_type_index = try buffer.findMemoryType(ctx, reqs.memory_type_bits, .{ .device_local_bit = true }),
        }, null);
        try ctx.device.bindImageMemory(self.depth_image, self.depth_mem, 0);
        self.depth_view = try ctx.device.createImageView(&.{
            .image = self.depth_image,
            .view_type = .@"2d",
            .format = depth_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .depth_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
    }

    fn create(self: *Swapchain, ctx: *const Context, window: sdl.video.Window) !void {
        const caps = try ctx.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.physical_device, ctx.surface);

        const formats = try ctx.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.physical_device, ctx.surface, ctx.allocator);
        defer ctx.allocator.free(formats);
        const modes = try ctx.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.physical_device, ctx.surface, ctx.allocator);
        defer ctx.allocator.free(modes);

        const fmt = chooseSurfaceFormat(formats);
        const pm = choosePresentMode(modes);
        const extent = chooseExtent(caps, window);

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0 and image_count > caps.max_image_count) image_count = caps.max_image_count;

        const gfx = ctx.queue_families.graphics;
        const prs = ctx.queue_families.present;
        const qfi = [_]u32{ gfx, prs };

        self.handle = try ctx.device.createSwapchainKHR(&.{
            .surface = ctx.surface,
            .min_image_count = image_count,
            .image_format = fmt.format,
            .image_color_space = fmt.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = if (gfx != prs) .concurrent else .exclusive,
            .queue_family_index_count = if (gfx != prs) 2 else 0,
            .p_queue_family_indices = if (gfx != prs) &qfi else null,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = pm,
            .clipped = .true,
            .old_swapchain = self.handle,
        }, null);

        self.format = fmt.format;
        self.extent = extent;
        self.images = try ctx.device.getSwapchainImagesAllocKHR(self.handle, ctx.allocator);

        std.debug.print("Swapchain created ({} images, {}x{})\n", .{ self.images.len, extent.width, extent.height });
    }

    fn createImageViews(self: *Swapchain, ctx: *const Context) !void {
        self.image_views = try ctx.allocator.alloc(vk.ImageView, self.images.len);
        for (self.images, 0..) |img, i| {
            self.image_views[i] = try ctx.device.createImageView(&.{
                .image = img,
                .view_type = .@"2d",
                .format = self.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
        }
    }

    fn createFramebuffers(self: *Swapchain, ctx: *const Context, render_pass: vk.RenderPass) !void {
        self.framebuffers = try ctx.allocator.alloc(vk.Framebuffer, self.image_views.len);
        for (self.image_views, 0..) |iv, i| {
            const attachments = [_]vk.ImageView{ iv, self.depth_view };
            self.framebuffers[i] = try ctx.device.createFramebuffer(&.{
                .render_pass = render_pass,
                .attachment_count = attachments.len,
                .p_attachments = &attachments,
                .width = self.extent.width,
                .height = self.extent.height,
                .layers = 1,
            }, null);
        }
    }
};

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |f| {
        if (f.format == .b8g8r8_srgb and f.color_space == .srgb_nonlinear_khr) return f;
    }
    return formats[0];
}

fn choosePresentMode(modes: []const vk.PresentModeKHR) vk.PresentModeKHR {
    for (modes) |m| {
        if (m == .mailbox_khr) return m;
    }
    return .fifo_khr;
}

fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR, window: sdl.video.Window) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.c.SDL_GetWindowSizeInPixels(window.value, &w, &h);
    return .{
        .width = std.math.clamp(@as(u32, @intCast(w)), caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(@as(u32, @intCast(h)), caps.min_image_extent.height, caps.max_image_extent.height),
    };
}
