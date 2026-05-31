const sdl = @import("sdl3");
const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");

const config = struct {
    const application_name = "Rhodo";
    const engine_name = "Rhodo Engine";
    const app_version: u32 = @bitCast(vk.makeApiVersion(0, 0, 0, 0));
    const engine_version: u32 = @bitCast(vk.makeApiVersion(0, 0, 0, 0));
    const api_version: u32 = @bitCast(vk.API_VERSION_1_4);
    const window_title = "Rhodo";
    const window_width = 800;
    const window_height = 600;
    const sdl_init_flags = sdl.InitFlags{
        .video = true,
    };
    const window_flags = sdl.video.Window.Flags{
        .vulkan = true,
        .resizable = true,
    };
    const enable_validation = builtin.mode == .Debug;

    const validation_layers: []const [*:0]const u8 = if (enable_validation)
        &.{"VK_LAYER_KHRONOS_validation"}
    else
        &.{};
    const device_extensions: []const [*:0]const u8 = &.{vk.extensions.khr_swapchain.name};
    const max_frames_in_flight: u32 = 2;
};

const vert_spv_path = "shaders/basic.vert.spv";
const frag_spv_path = "shaders/basic.frag.spv";

const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const Instance = vk.InstanceProxy;
const DeviceDispatch = vk.DeviceWrapper;
const Device = vk.DeviceProxy;

const QueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};

const Renderer = struct {
    io: std.Io,

    window: sdl.video.Window,

    vki: InstanceDispatch,
    instance: Instance,
    surface: vk.SurfaceKHR,

    physical_device: vk.PhysicalDevice,
    queue_families: QueueFamilyIndices,
    vkd: DeviceDispatch,
    device: Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,

    swapchain: vk.SwapchainKHR,
    swapchain_format: vk.Format,
    swapchain_extent: vk.Extent2D,
    swapchain_images: []vk.Image,
    swapchain_image_views: []vk.ImageView,

    render_pass: vk.RenderPass,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    framebuffers: []vk.Framebuffer,

    command_pool: vk.CommandPool,
    command_buffers: [config.max_frames_in_flight]vk.CommandBuffer,

    image_available: [config.max_frames_in_flight]vk.Semaphore,
    render_finished: [config.max_frames_in_flight]vk.Semaphore,
    in_flight: [config.max_frames_in_flight]vk.Fence,

    current_frame: u32,
};

var renderer: Renderer = undefined;
var gpa: std.heap.DebugAllocator(.{}) = .init;
const allocator = gpa.allocator();

pub fn run(io: std.Io) !void {
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.debug.print("Warning: Memory leak found", .{});
    }
    renderer.io = io;

    try initWindow();
    defer deinitWindow();

    try initVulkan();
    defer deinitVulkan();

    loop();
}

fn initWindow() !void {
    try sdl.init(config.sdl_init_flags);
    errdefer sdl.shutdown(); // Normal shutdown in deinit, this only runs if sth fails

    renderer.window = sdl.video.Window.init(
        config.window_title,
        config.window_width,
        config.window_height,
        config.window_flags,
    ) catch |err| {
        std.debug.print("Window.init failed: {}\n", .{err});
        return err;
    };

    _ = sdl.c.SDL_ShowWindow(renderer.window.value);
    std.debug.print("SDL Window created\n", .{});
}

fn deinitWindow() void {
    renderer.window.deinit();
    sdl.quit(config.sdl_init_flags);
    sdl.shutdown();

    std.debug.print("Successfully Shutdown\n", .{});
}

fn initVulkan() !void {
    renderer.current_frame = 0;

    try createInstance();
    try createSurface();
    try pickPhysicalDevice();
    try createLogicalDevice();
    try createSwapchain();
    try createImageViews();
    try createRenderPass();
    try createGraphicsPipeline();
    try createFramebuffers();
    try createCommandPool();
    try createCommandBuffers();
    try createSyncObjects();
}

fn deinitVulkan() void {
    renderer.device.deviceWaitIdle() catch {};

    for (0..config.max_frames_in_flight) |i| {
        renderer.device.destroySemaphore(renderer.image_available[i], null);
        renderer.device.destroySemaphore(renderer.render_finished[i], null);
        renderer.device.destroyFence(renderer.in_flight[i], null);
    }

    renderer.device.destroyCommandPool(renderer.command_pool, null);

    for (renderer.framebuffers) |fb| renderer.device.destroyFramebuffer(fb, null);
    allocator.free(renderer.framebuffers);

    renderer.device.destroyPipeline(renderer.pipeline, null);
    renderer.device.destroyPipelineLayout(renderer.pipeline_layout, null);
    renderer.device.destroyRenderPass(renderer.render_pass, null);

    for (renderer.swapchain_image_views) |iv| renderer.device.destroyImageView(iv, null);
    allocator.free(renderer.swapchain_image_views);
    allocator.free(renderer.swapchain_images);

    renderer.device.destroySwapchainKHR(renderer.swapchain, null);
    renderer.device.destroyDevice(null);

    renderer.instance.destroySurfaceKHR(renderer.surface, null);
    renderer.instance.destroyInstance(null);

    std.debug.print("Vulkan cleaned up\n", .{});
}

fn createInstance() !void {
    var ext_count: u32 = 0;
    const sdl_exts_ptr = sdl.c.SDL_Vulkan_GetInstanceExtensions(&ext_count) orelse {
        std.debug.print("Error SDL_Vulkan_GetInstanceExtensions failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.VulkanExtensionsFailed;
    };

    const sdl_exts = sdl_exts_ptr[0..ext_count];

    const loader: vk.PfnGetInstanceProcAddr = @ptrCast(sdl.c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.NoVkGetInstanceProcAddr);
    const vkb = BaseDispatch.load(loader);

    const app_info = vk.ApplicationInfo{
        .p_application_name = config.application_name,
        .application_version = config.app_version,
        .p_engine_name = config.engine_name,
        .engine_version = config.engine_version,
        .api_version = config.api_version,
    };

    const instance_info = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .enabled_extension_count = ext_count,
        .pp_enabled_extension_names = @ptrCast(sdl_exts.ptr),
        .enabled_layer_count = @intCast(config.validation_layers.len),
        .pp_enabled_layer_names = config.validation_layers.ptr,
    };

    const instance_handle = try vkb.createInstance(&instance_info, null);

    renderer.vki = InstanceDispatch.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr.?);
    renderer.instance = Instance.init(instance_handle, &renderer.vki);
    std.debug.print("Vulkan instance created\n", .{});
}

fn createSurface() !void {
    var surface: vk.SurfaceKHR = .null_handle;
    if (!sdl.c.SDL_Vulkan_CreateSurface(renderer.window.value, @ptrFromInt(@intFromEnum(renderer.instance.handle)), null, @ptrCast(&surface))) {
        std.debug.print("SDL_Vulkan_CreateSurface failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SurfaceCreationFailed;
    }
    renderer.surface = surface;
    std.debug.print("Vulkan Surface Created\n", .{});
}

fn pickPhysicalDevice() !void {
    const pdevs = try renderer.instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    if (pdevs.len == 0) return error.NoGPU;

    var best: ?vk.PhysicalDevice = null;
    var best_score: u32 = 0;

    for (pdevs) |pd| {
        if (!try isDeviceSuitable(pd)) continue;
        const score = scoreDevice(pd);
        const props_ = renderer.instance.getPhysicalDeviceProperties(pd);
        std.debug.print("Info Found device: {s}\n", .{std.mem.sliceTo(&props_.device_name, 0)});
        if (score > best_score) {
            best_score = score;
            best = pd;
        }
    }
    const pd = best orelse return error.NoSuitableGPU;
    renderer.physical_device = pd;
    renderer.queue_families = (try findQueueFamilies(pd)).?;
    const props = renderer.instance.getPhysicalDeviceProperties(pd);
    std.debug.print("Debug Selected GPU: {s}\n", .{std.mem.sliceTo(&props.device_name, 0)});
}

fn scoreDevice(pd: vk.PhysicalDevice) u32 {
    const props = renderer.instance.getPhysicalDeviceProperties(pd);
    return switch (props.device_type) {
        .discrete_gpu => 1000,
        .integrated_gpu => 100,
        .virtual_gpu => 10,
        .cpu => 1,
        else => 0,
    };
}

fn isDeviceSuitable(pd: vk.PhysicalDevice) !bool {
    if (try findQueueFamilies(pd) == null) return false;
    if (!try checkDeviceExtensionSupport(pd)) return false;

    const formats = try renderer.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pd, renderer.surface, allocator);
    defer allocator.free(formats);

    const modes = try renderer.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pd, renderer.surface, allocator);
    defer allocator.free(modes);

    return formats.len > 0 and modes.len > 0;
}

fn findQueueFamilies(pd: vk.PhysicalDevice) !?QueueFamilyIndices {
    const families = try renderer.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, allocator);
    defer allocator.free(families);

    var graphics: ?u32 = null;
    var present: ?u32 = null;

    for (families, 0..) |fam, i| {
        const idx: u32 = @intCast(i);
        if (fam.queue_flags.graphics_bit) graphics = idx;
        const presnt_support = try renderer.instance.getPhysicalDeviceSurfaceSupportKHR(pd, idx, renderer.surface);
        if (presnt_support == .true) present = idx;
        if (graphics != null and present != null) break;
    }

    if (graphics == null or present == null) return null;
    return .{
        .graphics = graphics.?,
        .present = present.?,
    };
}

fn checkDeviceExtensionSupport(pd: vk.PhysicalDevice) !bool {
    const exts = try renderer.instance.enumerateDeviceExtensionPropertiesAlloc(pd, null, allocator);
    defer allocator.free(exts);

    for (config.device_extensions) |required| {
        const req_name = std.mem.span(required);
        const found = for (exts) |ext| {
            if (std.mem.eql(u8, req_name, std.mem.sliceTo(&ext.extension_name, 0))) break true;
        } else false;

        if (!found) return false;
    }
    return true;
}

// Logical device
fn createLogicalDevice() !void {
    const priority = [_]f32{1.0};
    const gfx = renderer.queue_families.graphics;
    const prs = renderer.queue_families.present;

    var queue_infos: [2]vk.DeviceQueueCreateInfo = undefined;
    const queue_count: u32 = if (gfx == prs) 1 else 2;
    std.debug.print("Queue Count: {}\n", .{queue_count});
    queue_infos[0] = .{ .queue_family_index = gfx, .queue_count = 1, .p_queue_priorities = &priority };
    if (queue_count == 2)
        queue_infos[1] = .{ .queue_family_index = prs, .queue_count = 1, .p_queue_priorities = &priority };

    const device_create_info: vk.DeviceCreateInfo = .{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &queue_infos,
        .enabled_extension_count = @intCast(config.device_extensions.len),
        .pp_enabled_extension_names = config.device_extensions.ptr,
    };
    const device_handle = try renderer.instance.createDevice(renderer.physical_device, &device_create_info, null);

    renderer.vkd = DeviceDispatch.load(device_handle, renderer.vki.dispatch.vkGetDeviceProcAddr.?);
    renderer.device = Device.init(device_handle, &renderer.vkd);
    renderer.graphics_queue = renderer.device.getDeviceQueue(gfx, 0);
    renderer.present_queue = renderer.device.getDeviceQueue(prs, 0);
    std.debug.print("Logical device created\n", .{});
}

// Swapchain
fn createSwapchain() !void {
    const caps = try renderer.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(renderer.physical_device, renderer.surface);

    const formats = try renderer.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(renderer.physical_device, renderer.surface, allocator);
    defer allocator.free(formats);

    const modes = try renderer.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(renderer.physical_device, renderer.surface, allocator);
    defer allocator.free(modes);

    const fmt = chooseSurfaceFormat(formats);
    const pm = choosePresentModes(modes);
    const extent = chooseExtent(caps);

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0 and image_count > caps.max_image_count) image_count = caps.max_image_count;

    const gfx = renderer.queue_families.graphics;
    const prs = renderer.queue_families.present;
    const qfi = [_]u32{ gfx, prs };

    const swapchain_create_info: vk.SwapchainCreateInfoKHR = .{
        .surface = renderer.surface,
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
        .old_swapchain = .null_handle,
    };
    renderer.swapchain = try renderer.device.createSwapchainKHR(&swapchain_create_info, null);

    renderer.swapchain_format = fmt.format;
    renderer.swapchain_extent = extent;

    renderer.swapchain_images = try renderer.device.getSwapchainImagesAllocKHR(renderer.swapchain, allocator);

    std.debug.print("Swapchain created ({} images, {}x{})\n", .{
        renderer.swapchain_images.len,
        extent.width,
        extent.height,
    });
}

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    for (formats) |f| {
        if (f.format == .b8g8r8_srgb and f.color_space == .srgb_nonlinear_khr) return f;
    }
    return formats[0];
}

fn choosePresentModes(modes: []const vk.PresentModeKHR) vk.PresentModeKHR {
    for (modes) |m| {
        if (m == .mailbox_khr) return m;
    }
    return .fifo_khr;
}

fn chooseExtent(caps: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.c.SDL_GetWindowSizeInPixels(renderer.window.value, &w, &h);

    return .{
        .width = std.math.clamp(@as(u32, @intCast(w)), caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(@as(u32, @intCast(h)), caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn createImageViews() !void {
    renderer.swapchain_image_views = try allocator.alloc(vk.ImageView, renderer.swapchain_images.len);
    for (renderer.swapchain_images, 0..) |img, i| {
        const image_view_create_info: vk.ImageViewCreateInfo = .{
            .image = img,
            .view_type = .@"2d",
            .format = renderer.swapchain_format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        renderer.swapchain_image_views[i] = try renderer.device.createImageView(&image_view_create_info, null);
    }
    std.debug.print("Image views created\n", .{});
}

// Render pass
fn createRenderPass() !void {
    const color_attachment: vk.AttachmentDescription = .{
        .format = renderer.swapchain_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const color_ref: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_ref),
    };
    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };

    const render_pass_creation_info: vk.RenderPassCreateInfo = .{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    };
    renderer.render_pass = try renderer.device.createRenderPass(&render_pass_creation_info, null);
    std.debug.print("Render pass created\n", .{});
}

// Graphics Pipeline
fn createGraphicsPipeline() !void {
    const vert_spv = try std.Io.Dir.cwd().readFileAlloc(renderer.io, vert_spv_path, allocator, .unlimited);
    defer allocator.free(vert_spv);
    const frag_spv = try std.Io.Dir.cwd().readFileAlloc(renderer.io, frag_spv_path, allocator, .unlimited);
    defer allocator.free(frag_spv);

    const vert = try createShaderModule(vert_spv);
    defer renderer.device.destroyShaderModule(vert, null);

    const frag = try createShaderModule(frag_spv);
    defer renderer.device.destroyShaderModule(frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main" },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };

    renderer.pipeline_layout = try renderer.device.createPipelineLayout(&.{}, null);

    var pipeline: vk.Pipeline = .null_handle;
    var pipeline_create_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 0,
            .vertex_attribute_description_count = 0,
        },
        .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list, .primitive_restart_enable = .false },
        .p_viewport_state = &vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        },
        .p_rasterization_state = &vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .line_width = 1.0,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
        },
        .p_multisample_state = &vk.PipelineMultisampleStateCreateInfo{
            .sample_shading_enable = .false,
            .rasterization_samples = .{ .@"1_bit" = true },
            .min_sample_shading = 0.0,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_color_blend_state = &vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{.{
                .blend_enable = .false,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            }},
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        },
        .layout = renderer.pipeline_layout,
        .render_pass = renderer.render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    _ = try renderer.device.createGraphicsPipelines(.null_handle, @as(*[1]vk.GraphicsPipelineCreateInfo, &pipeline_create_info), null, @as(*[1]vk.Pipeline, &pipeline));

    renderer.pipeline = pipeline;
    std.debug.print("Graphics pipeline created\n", .{});
}

fn createShaderModule(code: []const u8) !vk.ShaderModule {
    const shader_module_create_info: vk.ShaderModuleCreateInfo = .{
        .code_size = code.len,
        .p_code = @ptrCast(@alignCast(code.ptr)),
    };
    return renderer.device.createShaderModule(&shader_module_create_info, null);
}

// Frame Buffers
fn createFramebuffers() !void {
    renderer.framebuffers = try allocator.alloc(vk.Framebuffer, renderer.swapchain_image_views.len);
    for (renderer.swapchain_image_views, 0..) |iv, i| {
        const frame_buffer_create_info: vk.FramebufferCreateInfo = .{
            .render_pass = renderer.render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&iv),
            .width = renderer.swapchain_extent.width,
            .height = renderer.swapchain_extent.height,
            .layers = 1,
        };
        renderer.framebuffers[i] = try renderer.device.createFramebuffer(&frame_buffer_create_info, null);
    }
    std.debug.print("Framebuffers created\n", .{});
}

// Command pool and command
fn createCommandPool() !void {
    const command_pool_create_info: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer_bit = true },
        .queue_family_index = renderer.queue_families.graphics,
    };
    renderer.command_pool = try renderer.device.createCommandPool(&command_pool_create_info, null);
}

fn createCommandBuffers() !void {
    const command_buffer_allocate_info: vk.CommandBufferAllocateInfo = .{
        .command_pool = renderer.command_pool,
        .level = .primary,
        .command_buffer_count = config.max_frames_in_flight,
    };
    try renderer.device.allocateCommandBuffers(&command_buffer_allocate_info, &renderer.command_buffers);
}

fn recordCommandBuffer(cmd: vk.CommandBuffer, image_index: u32) !void {
    try renderer.device.beginCommandBuffer(cmd, &.{});

    renderer.device.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(renderer.swapchain_extent.width),
        .height = @floatFromInt(renderer.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    renderer.device.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = renderer.swapchain_extent,
    }});

    const render_pass_begin_info: vk.RenderPassBeginInfo = .{
        .render_pass = renderer.render_pass,
        .framebuffer = renderer.framebuffers[image_index],
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = renderer.swapchain_extent },
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&vk.ClearValue{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } }),
    };
    renderer.device.cmdBeginRenderPass(cmd, &render_pass_begin_info, .@"inline");
    renderer.device.cmdBindPipeline(cmd, .graphics, renderer.pipeline);
    renderer.device.cmdDraw(cmd, 3, 1, 0, 0);
    renderer.device.cmdEndRenderPass(cmd);

    try renderer.device.endCommandBuffer(cmd);
}

// Sync objects
fn createSyncObjects() !void {
    for (0..config.max_frames_in_flight) |i| {
        renderer.image_available[i] = try renderer.device.createSemaphore(&.{}, null);
        renderer.render_finished[i] = try renderer.device.createSemaphore(&.{}, null);

        renderer.in_flight[i] = try renderer.device.createFence(
            &.{ .flags = .{ .signaled_bit = true } },
            null,
        );
    }
    std.debug.print("Sync objects created\n", .{});
}

// Draw Frames
fn drawFrame() !void {
    const f = renderer.current_frame;

    _ = try renderer.device.waitForFences(&.{renderer.in_flight[f]}, .true, std.math.maxInt(u64));
    try renderer.device.resetFences(&.{renderer.in_flight[f]});

    const acquired = try renderer.device.acquireNextImageKHR(
        renderer.swapchain,
        std.math.maxInt(u64),
        renderer.image_available[f],
        .null_handle,
    );
    const image_index = acquired.image_index;

    const cmd = renderer.command_buffers[f];
    try renderer.device.resetCommandBuffer(cmd, .{});
    try recordCommandBuffer(cmd, image_index);

    const wait_stage: vk.PipelineStageFlags = .{ .color_attachment_output_bit = true };

    const submit_info: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&renderer.image_available[f]),
        .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmd),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&renderer.render_finished[f]),
    };
    try renderer.device.queueSubmit(renderer.graphics_queue, &.{submit_info}, renderer.in_flight[f]);

    const present_info_khr: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&renderer.render_finished[f]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&renderer.swapchain),
        .p_image_indices = @ptrCast(&image_index),
    };
    _ = try renderer.device.queuePresentKHR(renderer.present_queue, &present_info_khr);

    renderer.current_frame = (f + 1) % config.max_frames_in_flight;
}

fn loop() void {
    var running = true;
    while (running) {
        while (sdl.events.poll()) |event| {
            switch (event) {
                .quit => running = false,
                .terminating => running = false,
                .key_down => |k| {
                    if (k.key == .escape) running = false;
                },
                else => {},
            }
        }
        drawFrame() catch |err| {
            std.debug.print("drawFrame error: {}\n", .{err});
            running = false;
        };
    }
}
