const std = @import("std");
pub const Renderer = @import("renderer/main.zig").Renderer;
pub const MeshHandle = @import("renderer/main.zig").MeshHandle;
pub const ShaderHandle = @import("renderer/main.zig").ShaderHandle;
pub const TextureHandle = @import("renderer/main.zig").TextureHandle;
pub const Model = @import("renderer/main.zig").Model;
pub const Key = @import("input.zig").Key;
pub const PadButton = @import("input.zig").PadButton;
pub const PadAxis = @import("input.zig").PadAxis;
pub const Binding = @import("input.zig").Binding;
pub const Devices = @import("input.zig").Devices;
pub const Event = @import("input.zig").Event;
pub const Input = @import("input.zig").Input;
pub const shader = @import("renderer/main.zig").shader;
pub const mesh = @import("renderer/mesh.zig");
pub const math = @import("math.zig");
pub const Camera = @import("camera.zig").Camera;
pub const Physics = @import("physics.zig").Physics;
pub const BodyHandle = @import("physics.zig").BodyHandle;
pub const BodyType = @import("physics.zig").BodyType;
pub const ShapeKind = @import("physics.zig").ShapeKind;
pub const collider_colors = @import("physics.zig").collider_colors;
pub const CharacterHandle = @import("physics.zig").CharacterHandle;
pub const Character = @import("physics.zig").Character;
pub const Audio = @import("audio.zig").Audio;
pub const SoundHandle = @import("audio.zig").SoundHandle;
pub const imgui = @import("imgui.zig").imgui;

pub const Transform = math.Transform;

// Test discovery: `zig build test` only runs tests in files reachable from
// here. Keep this list in sync with `grep -rl '^test ' src`.
test {
    _ = @import("camera.zig");
    _ = @import("input.zig");
    _ = @import("math.zig");
    _ = @import("physics.zig");
    _ = @import("renderer/debug.zig");
    _ = @import("renderer/mesh.zig");
    _ = @import("renderer/texture.zig");
}
// ponytail: ceiling 1024 entities, no spatial query. BVH when you need culling.
