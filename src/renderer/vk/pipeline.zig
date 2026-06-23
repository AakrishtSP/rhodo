const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

// Shared depth format for the render pass + the swapchain's depth image.
pub const depth_format: vk.Format = .d32_sfloat;

// Per-pipeline knobs. Defaults reproduce the old triangle pipeline (no vertex
// input, no depth, no blend), so a bare `.{}` still works. Not a builder
// framework — just the fields the two concrete pipelines (mesh, sprite) differ on.
pub const Config = struct {
    bindings: []const vk.VertexInputBindingDescription = &.{},
    attributes: []const vk.VertexInputAttributeDescription = &.{},
    set_layouts: []const vk.DescriptorSetLayout = &.{},
    push_constant_ranges: []const vk.PushConstantRange = &.{},
    depth_test: bool = false,
    blend: bool = false,
    cull_back: bool = false,
};

// Render pass + pipeline layout + pipeline. Render pass is format-dependent
// (rebuilt only if swapchain format changes, which doesn't happen on a plain
// resize) and is created once in init(). Pipeline is rebuilt by reload() any
// time the shaders change — that's the shader-playground hot-reload path.
pub const Pipeline = struct {
    render_pass: vk.RenderPass,
    layout: vk.PipelineLayout,
    handle: vk.Pipeline,
    config: Config,

    pub fn init(ctx: *const Context, io: std.Io, format: vk.Format, vert_path: []const u8, frag_path: []const u8, config: Config) !Pipeline {
        var self: Pipeline = undefined;
        self.config = config;
        self.render_pass = try createRenderPass(ctx, format);
        errdefer ctx.device.destroyRenderPass(self.render_pass, null);

        self.layout = try createLayout(ctx, config);
        errdefer ctx.device.destroyPipelineLayout(self.layout, null);

        self.handle = try buildPipeline(ctx, io, self.layout, self.render_pass, vert_path, frag_path, config);
        return self;
    }

    pub fn deinit(self: *Pipeline, ctx: *const Context) void {
        ctx.device.destroyPipeline(self.handle, null);
        ctx.device.destroyPipelineLayout(self.layout, null);
        ctx.device.destroyRenderPass(self.render_pass, null);
    }

    // Rebuild just the pipeline (not render pass/layout) from new shader source.
    // Old pipeline isn't destroyed until the new one compiles successfully, so a
    // shader with a compile error leaves the previous one running instead of
    // leaving the renderer with no pipeline at all.
    pub fn reload(self: *Pipeline, ctx: *const Context, io: std.Io, vert_path: []const u8, frag_path: []const u8) !void {
        const new_handle = try buildPipeline(ctx, io, self.layout, self.render_pass, vert_path, frag_path, self.config);
        ctx.device.destroyPipeline(self.handle, null);
        self.handle = new_handle;
        std.debug.print("Pipeline reloaded from {s} / {s}\n", .{ vert_path, frag_path });
    }
};

pub fn createLayout(ctx: *const Context, config: Config) !vk.PipelineLayout {
    return ctx.device.createPipelineLayout(&.{
        .set_layout_count = @intCast(config.set_layouts.len),
        .p_set_layouts = config.set_layouts.ptr,
        .push_constant_range_count = @intCast(config.push_constant_ranges.len),
        .p_push_constant_ranges = config.push_constant_ranges.ptr,
    }, null);
}

fn createRenderPass(ctx: *const Context, format: vk.Format) !vk.RenderPass {
    const color_attachment: vk.AttachmentDescription = .{
        .format = format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const depth_attachment: vk.AttachmentDescription = .{
        .format = depth_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .dont_care,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .depth_stencil_attachment_optimal,
    };
    const color_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const depth_ref: vk.AttachmentReference = .{ .attachment = 1, .layout = .depth_stencil_attachment_optimal };
    const subpass: vk.SubpassDescription = .{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_ref),
        .p_depth_stencil_attachment = &depth_ref,
    };
    const dependency: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
    };

    const attachments = [_]vk.AttachmentDescription{ color_attachment, depth_attachment };
    return ctx.device.createRenderPass(&.{
        .attachment_count = attachments.len,
        .p_attachments = &attachments,
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dependency),
    }, null);
}

pub fn buildPipeline(ctx: *const Context, io: std.Io, layout: vk.PipelineLayout, render_pass: vk.RenderPass, vert_path: []const u8, frag_path: []const u8, config: Config) !vk.Pipeline {
    const vert_spv = try std.Io.Dir.cwd().readFileAlloc(io, vert_path, ctx.allocator, .unlimited);
    defer ctx.allocator.free(vert_spv);
    const frag_spv = try std.Io.Dir.cwd().readFileAlloc(io, frag_path, ctx.allocator, .unlimited);
    defer ctx.allocator.free(frag_spv);

    const vert = try createShaderModule(ctx, vert_spv);
    defer ctx.device.destroyShaderModule(vert, null);
    const frag = try createShaderModule(ctx, frag_spv);
    defer ctx.device.destroyShaderModule(frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main" },
    };
    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };

    const blend_attachment: vk.PipelineColorBlendAttachmentState = if (config.blend) .{
        .blend_enable = .true,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    } else .{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    var pipeline: vk.Pipeline = .null_handle;
    var pipeline_create_info: vk.GraphicsPipelineCreateInfo = .{
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = @intCast(config.bindings.len),
            .p_vertex_binding_descriptions = config.bindings.ptr,
            .vertex_attribute_description_count = @intCast(config.attributes.len),
            .p_vertex_attribute_descriptions = config.attributes.ptr,
        },
        .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list, .primitive_restart_enable = .false },
        .p_viewport_state = &vk.PipelineViewportStateCreateInfo{ .viewport_count = 1, .scissor_count = 1 },
        .p_rasterization_state = &vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .line_width = 1.0,
            .cull_mode = if (config.cull_back) .{ .back_bit = true } else .{},
            .front_face = .counter_clockwise,
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
        .p_depth_stencil_state = &vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = if (config.depth_test) .true else .false,
            .depth_write_enable = if (config.depth_test) .true else .false,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
        },
        .p_color_blend_state = &vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&blend_attachment),
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        },
        .layout = layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    _ = try ctx.device.createGraphicsPipelines(.null_handle, @as(*[1]vk.GraphicsPipelineCreateInfo, &pipeline_create_info), null, @as(*[1]vk.Pipeline, &pipeline));
    return pipeline;
}

fn createShaderModule(ctx: *const Context, code: []const u8) !vk.ShaderModule {
    return ctx.device.createShaderModule(&.{
        .code_size = code.len,
        .p_code = @ptrCast(@alignCast(code.ptr)),
    }, null);
}
