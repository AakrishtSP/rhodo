const std = @import("std");
pub const Renderer = @import("renderer/main.zig").Renderer;
pub const MeshHandle = @import("renderer/main.zig").MeshHandle;
pub const ShaderHandle = @import("renderer/main.zig").ShaderHandle;
pub const TextureHandle = @import("renderer/main.zig").TextureHandle;
pub const Model = @import("renderer/main.zig").Model;
pub const KeyCode = @import("input.zig").KeyCode;
pub const Event = @import("input.zig").Event;
pub const Input = @import("input.zig").Input;
pub const shader = @import("renderer/main.zig").shader;
pub const mesh = @import("renderer/mesh.zig");
pub const math = @import("math.zig");
pub const Camera = @import("camera.zig").Camera;
pub const Physics = @import("physics.zig").Physics;
pub const BodyHandle = @import("physics.zig").BodyHandle;
pub const imgui = @import("imgui.zig").imgui;

pub const Transform = math.Transform;
pub var transforms: [1024]Transform = undefined;
// ponytail: ceiling 1024 entities, no spatial query. BVH when you need culling.
