const math = @import("math.zig");
const Model = @import("renderer/main.zig").Model;
const Physics = @import("physics.zig").Physics;

pub const Entity = u32;

// Data-oriented game objects: every entity is exactly one box body (static or
// dynamic) + an optional visual. No pointers, no methods on entities, no
// inheritance — parallel arrays keyed by stable index, systems iterate them.
// This is the one place an object type is composed (see sandbox spawn fns).
// Tombstones on despawn (slots leak until restart resets all); free-list reuse
// when a single run exceeds 1024 spawns. Non-physical entities (bodiless
// triggers/markers) need an id↔body map — add it then, not now.
pub const Entities = struct {
    models: [1024]?Model = .{null} ** 1024,
    is_static: [1024]bool = .{false} ** 1024,
    alive: [1024]bool = .{false} ** 1024,
    count: u32 = 0,

    // Compose mesh + body in one call. id doubles as the physics/transform
    // index (all bodies are added through here, so they stay lockstep).
    pub fn spawn(self: *Entities, sim: *Physics, pos: math.Vec3, half: math.Vec3, is_static: bool, model: ?Model) !Entity {
        if (self.count >= 1024) return error.TooManyEntities;
        const id = try sim.addBox(pos, half, is_static);
        self.models[id] = model;
        self.is_static[id] = is_static;
        self.alive[id] = true;
        if (id >= self.count) self.count = id + 1;
        return id;
    }

    pub fn despawn(self: *Entities, sim: *Physics, id: Entity) void {
        if (id >= self.count or !self.alive[id]) return;
        sim.removeBox(id);
        self.alive[id] = false;
        self.models[id] = null;
    }

    pub fn reset(self: *Entities) void {
        self.models = .{null} ** 1024;
        self.is_static = .{false} ** 1024;
        self.alive = .{false} ** 1024;
        self.count = 0;
    }
};
