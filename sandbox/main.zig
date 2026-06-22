const std = @import("std");
const rhodo = @import("rhodo");

const mesh_obj_path = "assets/suzanne.obj";

var gpa: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const allocator = gpa.allocator();
    defer {
        const status = gpa.deinit();
        if (status == .leak) std.debug.print("Warning: Memory leak found\n", .{});
    }

    // Load the mesh in the sandbox — the renderer just uploads what it's given.
    const mesh_data = rhodo.mesh.loadObj(io, allocator, mesh_obj_path) catch |err| blk: {
        std.debug.print("No {s} ({}), drawing cube fallback\n", .{ mesh_obj_path, err });
        break :blk try rhodo.mesh.cube(allocator);
    };

    var renderer = try rhodo.Renderer.init(allocator, io, mesh_data);
    defer renderer.deinit();

    var watcher = try ShaderWatcher.init(io, "shaders/mesh.vert.spv", "shaders/mesh.frag.spv");

    var running = true;
    while (running) {
        while (renderer.pollEvent()) |event| {
            switch (event) {
                .quit => running = false,
                .resized => renderer.notifyResized(),
            }
        }

        if (try watcher.checkChanged(io)) {
            renderer.reloadShaders(watcher.vert_path, watcher.frag_path) catch |err| {
                std.debug.print("Shader reload failed, keeping previous pipeline: {}\n", .{err});
            };
        }

        renderer.beginFrame() catch |err| {
            std.debug.print("beginFrame error: {}\n", .{err});
            running = false;
            continue;
        };
        renderer.endFrame() catch |err| {
            std.debug.print("endFrame error: {}\n", .{err});
            running = false;
        };
    }
}

// Shader playground hot-reload: polls mtime once per frame rather than running
// a filesystem watch thread. ponytail: O(1) stat() per shader per frame is fine
// at 2 files; switch to an actual inotify/ReadDirectoryChangesW watch only if
// you end up watching many shader variants.
const ShaderWatcher = struct {
    vert_path: []const u8,
    frag_path: []const u8,
    vert_mtime: std.Io.Timestamp,
    frag_mtime: std.Io.Timestamp,

    fn init(io: std.Io, vert_path: []const u8, frag_path: []const u8) !ShaderWatcher {
        return .{
            .vert_path = vert_path,
            .frag_path = frag_path,
            .vert_mtime = try mtimeOf(io, vert_path),
            .frag_mtime = try mtimeOf(io, frag_path),
        };
    }

    fn checkChanged(self: *ShaderWatcher, io: std.Io) !bool {
        const vm = mtimeOf(io, self.vert_path) catch return false;
        const fm = mtimeOf(io, self.frag_path) catch return false;
        if (vm.nanoseconds == self.vert_mtime.nanoseconds and fm.nanoseconds == self.frag_mtime.nanoseconds) return false;
        self.vert_mtime = vm;
        self.frag_mtime = fm;
        return true;
    }

    fn mtimeOf(io: std.Io, path: []const u8) !std.Io.Timestamp {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        return stat.mtime;
    }
};
