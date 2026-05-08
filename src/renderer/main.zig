const sdl = @import("sdl3");
const vk = @import("vulkan");
const std = @import("std");

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
};

const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const Instance = vk.InstanceProxy;

const Renderer = struct {
    window: sdl.video.Window,
    vki: InstanceDispatch,
    instance: Instance,
    surface: vk.SurfaceKHR,
};

var renderer: Renderer = undefined;

pub fn run() !void {
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
    var ext_count: u32 = 0;
    const sdl_exts_ptr =
        sdl.c.SDL_Vulkan_GetInstanceExtensions(&ext_count) orelse {
            std.debug.print("GetInstanceExtensions failed: {s}\n", .{sdl.c.SDL_GetError()});
            return error.VulkanExtensionsFailed;
        };
    const sdl_exts = sdl_exts_ptr[0..ext_count];

    std.debug.print("vulkan extensions ({}): \n", .{ext_count});
    for (sdl_exts) |ext| std.debug.print("    {s}\n", .{ext});
    const loader: vk.PfnGetInstanceProcAddr = @ptrCast(
        sdl.c.SDL_Vulkan_GetVkGetInstanceProcAddr() orelse {
            std.debug.print("SDL_Vulkan_GetVkGetInstanceProcAddr returned null", .{});
            return error.NoVkGetInstanceProcAddr;
        },
    );
    const vkb = BaseDispatch.load(loader);
    const app_info = vk.ApplicationInfo{
        .p_application_name = config.application_name,
        .application_version = config.app_version,
        .p_engine_name = config.engine_name,
        .engine_version = config.engine_version,
        .api_version = config.api_version,
    };

    const instance_handle = vkb.createInstance(&.{
        .p_application_info = &app_info,
        .enabled_extension_count = ext_count,
        .pp_enabled_extension_names = @ptrCast(sdl_exts.ptr),
    }, null) catch |err| {
        std.debug.print("Error createInstance failed: {}\n", .{err});
        return err;
    };
    renderer.vki = InstanceDispatch.load(
        instance_handle,
        vkb.dispatch.vkGetInstanceProcAddr.?,
    );

    renderer.instance = Instance.init(instance_handle, &renderer.vki);

    std.debug.print("Vulkan instance created\n", .{});

    var surface: vk.SurfaceKHR = .null_handle;
    if (!sdl.c.SDL_Vulkan_CreateSurface(
        renderer.window.value,
        @ptrFromInt(@intFromEnum(instance_handle)),
        null,
        @ptrCast(&surface),
    )) {
        std.debug.print("Error CreateSurface Failed: {s}\n", .{sdl.c.SDL_GetError()});
        return error.SurfaceCreationFailed;
    }
    renderer.surface = surface;

    std.debug.print("Vulkan Surface Created\n", .{});
}

fn deinitVulkan() void {
    renderer.instance.destroySurfaceKHR(renderer.surface, null);
    renderer.instance.destroyInstance(null);
    std.debug.print("Cleaned up Vulkan\n", .{});
}

// no errors here
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
    }
}
