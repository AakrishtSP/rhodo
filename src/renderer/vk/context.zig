const std = @import("std");
const sdl = @import("sdl3");
const vk = @import("vulkan");
const builtin = @import("builtin");

// vulkan-zig wrappers are types that expose every command — no flag list.
const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;

const enable_validation = builtin.mode == .Debug;
const validation_layers: []const [*:0]const u8 = if (enable_validation)
    &.{"VK_LAYER_KHRONOS_validation"}
else
    &.{};
const device_extensions: []const [*:0]const u8 = &.{vk.extensions.khr_swapchain.name};

pub const QueueFamilyIndices = struct {
    graphics: u32,
    present: u32,
};

// Everything needed to talk to a GPU and a surface: instance, chosen physical
// device, logical device, queues. Created once in init() and never mutated
// or torn down individually — swapchain/pipeline/resources are rebuilt against
// this, this itself is not rebuilt.
pub const Context = struct {
    // Heap-allocated: InstanceProxy/DeviceProxy hold a pointer to these, so the
    // dispatch tables must live at a stable address. A by-value Context (init
    // returns one, Renderer embeds one) would otherwise leave those proxies
    // pointing at a dead stack frame — the createImageView null-fn panic.
    vki: *InstanceDispatch,
    instance: vk.InstanceProxy,
    surface: vk.SurfaceKHR,

    physical_device: vk.PhysicalDevice,
    queue_families: QueueFamilyIndices,
    vkd: *DeviceDispatch,
    device: vk.DeviceProxy,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, window: sdl.video.Window) !Context {
        var self: Context = undefined;
        self.allocator = allocator;

        try self.createInstance();
        errdefer self.instance.destroyInstance(null);

        try self.createSurface(window);
        errdefer self.instance.destroySurfaceKHR(self.surface, null);

        try self.pickPhysicalDevice();
        try self.createLogicalDevice();

        return self;
    }

    pub fn deinit(self: *Context) void {
        self.device.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);
        self.allocator.destroy(self.vkd);
        self.allocator.destroy(self.vki);
    }

    fn createInstance(self: *Context) !void {
        var ext_count: u32 = 0;
        const sdl_exts_ptr = sdl.c.SDL_Vulkan_GetInstanceExtensions(&ext_count) orelse {
            std.debug.print("Error SDL_Vulkan_GetInstanceExtensions failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.VulkanExtensionsFailed;
        };
        const sdl_exts = sdl_exts_ptr[0..ext_count];

        const loader: vk.PfnGetInstanceProcAddr = @ptrCast(sdl.c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse return error.NoVkGetInstanceProcAddr);
        const vkb = BaseDispatch.load(loader);

        const app_info = vk.ApplicationInfo{
            .p_application_name = "Rhodo",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = "Rhodo Engine",
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_4),
        };

        const instance_info = vk.InstanceCreateInfo{
            .p_application_info = &app_info,
            .enabled_extension_count = ext_count,
            .pp_enabled_extension_names = @ptrCast(sdl_exts.ptr),
            .enabled_layer_count = @intCast(validation_layers.len),
            .pp_enabled_layer_names = validation_layers.ptr,
        };

        const instance_handle = try vkb.createInstance(&instance_info, null);
        self.vki = try self.allocator.create(InstanceDispatch);
        self.vki.* = InstanceDispatch.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = vk.InstanceProxy.init(instance_handle, self.vki);
        std.debug.print("Vulkan instance created\n", .{});
    }

    fn createSurface(self: *Context, window: sdl.video.Window) !void {
        var surface: vk.SurfaceKHR = .null_handle;
        if (!sdl.c.SDL_Vulkan_CreateSurface(window.value, @ptrFromInt(@intFromEnum(self.instance.handle)), null, @ptrCast(&surface))) {
            std.debug.print("SDL_Vulkan_CreateSurface failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.SurfaceCreationFailed;
        }
        self.surface = surface;
        std.debug.print("Vulkan Surface Created\n", .{});
    }

    fn pickPhysicalDevice(self: *Context) !void {
        const pdevs = try self.instance.enumeratePhysicalDevicesAlloc(self.allocator);
        defer self.allocator.free(pdevs);
        if (pdevs.len == 0) return error.NoGPU;

        var best: ?vk.PhysicalDevice = null;
        var best_score: u32 = 0;

        for (pdevs) |pd| {
            if (!try self.isDeviceSuitable(pd)) continue;
            const score = self.scoreDevice(pd);
            const props_ = self.instance.getPhysicalDeviceProperties(pd);
            std.debug.print("Info Found device: {s}\n", .{std.mem.sliceTo(&props_.device_name, 0)});
            if (score > best_score) {
                best_score = score;
                best = pd;
            }
        }
        const pd = best orelse return error.NoSuitableGPU;
        self.physical_device = pd;
        self.queue_families = (try self.findQueueFamilies(pd)).?;
        const props = self.instance.getPhysicalDeviceProperties(pd);
        std.debug.print("Debug Selected GPU: {s}\n", .{std.mem.sliceTo(&props.device_name, 0)});
    }

    fn scoreDevice(self: *Context, pd: vk.PhysicalDevice) u32 {
        const props = self.instance.getPhysicalDeviceProperties(pd);
        return switch (props.device_type) {
            .discrete_gpu => 1000,
            .integrated_gpu => 100,
            .virtual_gpu => 10,
            .cpu => 1,
            else => 0,
        };
    }

    fn isDeviceSuitable(self: *Context, pd: vk.PhysicalDevice) !bool {
        if (try self.findQueueFamilies(pd) == null) return false;
        if (!try self.checkDeviceExtensionSupport(pd)) return false;

        const formats = try self.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pd, self.surface, self.allocator);
        defer self.allocator.free(formats);
        const modes = try self.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pd, self.surface, self.allocator);
        defer self.allocator.free(modes);

        return formats.len > 0 and modes.len > 0;
    }

    fn findQueueFamilies(self: *Context, pd: vk.PhysicalDevice) !?QueueFamilyIndices {
        const families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, self.allocator);
        defer self.allocator.free(families);

        var graphics: ?u32 = null;
        var present: ?u32 = null;
        for (families, 0..) |fam, i| {
            const idx: u32 = @intCast(i);
            if (fam.queue_flags.graphics_bit) graphics = idx;
            const support = try self.instance.getPhysicalDeviceSurfaceSupportKHR(pd, idx, self.surface);
            if (support == .true) present = idx;
            if (graphics != null and present != null) break;
        }
        if (graphics == null or present == null) return null;
        return .{ .graphics = graphics.?, .present = present.? };
    }

    fn checkDeviceExtensionSupport(self: *Context, pd: vk.PhysicalDevice) !bool {
        const exts = try self.instance.enumerateDeviceExtensionPropertiesAlloc(pd, null, self.allocator);
        defer self.allocator.free(exts);

        for (device_extensions) |required| {
            const req_name = std.mem.span(required);
            const found = for (exts) |ext| {
                if (std.mem.eql(u8, req_name, std.mem.sliceTo(&ext.extension_name, 0))) break true;
            } else false;
            if (!found) return false;
        }
        return true;
    }

    fn createLogicalDevice(self: *Context) !void {
        const priority = [_]f32{1.0};
        const gfx = self.queue_families.graphics;
        const prs = self.queue_families.present;

        var queue_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        const queue_count: u32 = if (gfx == prs) 1 else 2;
        queue_infos[0] = .{ .queue_family_index = gfx, .queue_count = 1, .p_queue_priorities = &priority };
        if (queue_count == 2)
            queue_infos[1] = .{ .queue_family_index = prs, .queue_count = 1, .p_queue_priorities = &priority };

        const device_create_info: vk.DeviceCreateInfo = .{
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &queue_infos,
            .enabled_extension_count = @intCast(device_extensions.len),
            .pp_enabled_extension_names = device_extensions.ptr,
        };
        const device_handle = try self.instance.createDevice(self.physical_device, &device_create_info, null);

        self.vkd = try self.allocator.create(DeviceDispatch);
        self.vkd.* = DeviceDispatch.load(device_handle, self.vki.dispatch.vkGetDeviceProcAddr.?);
        self.device = vk.DeviceProxy.init(device_handle, self.vkd);
        self.graphics_queue = self.device.getDeviceQueue(gfx, 0);
        self.present_queue = self.device.getDeviceQueue(prs, 0);
        std.debug.print("Logical device created\n", .{});
    }
};
