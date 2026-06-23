const std = @import("std");
pub const Renderer = @import("renderer/main.zig").Renderer;
pub const MeshHandle = @import("renderer/main.zig").MeshHandle;
pub const ShaderHandle = @import("renderer/main.zig").ShaderHandle;
pub const shader = @import("renderer/main.zig").shader;
pub const mesh = @import("renderer/mesh.zig");
pub const math = @import("math.zig");

pub const Transform = struct { pos: math.Vec3, rot: math.Vec4, scale: math.Vec3 };
pub var transforms: [1024]Transform = undefined;
// ponytail: ceiling 1024 entities, no spatial query. BVH when you need culling.
