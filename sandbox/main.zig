const std = @import("std");
const rhodo = @import("rhodo");

const mesh_obj_path = "assets/suzanne.obj";

var gpa: std.heap.DebugAllocator(.{}) = .init;

// ponytail: clock_gettime with raw CLOCK_MONOTONIC. Zig 0.16 removed std.time.Timer.
fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.os.linux.clockid_t.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

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

    var renderer = try rhodo.Renderer.init(allocator, io);
    defer renderer.deinit();

    const lit_shader: rhodo.ShaderHandle = 0; // ponytail: shader 0 loaded by init
    const flat_shader = try renderer.loadShader(rhodo.shader.mesh_vert, rhodo.shader.flat_frag);

    const suzanne = try renderer.uploadMesh(mesh_data);
    const cube = try renderer.uploadMesh(try rhodo.mesh.cube(allocator));

    var watcher = try ShaderWatcher.init(io, "shaders/mesh.vert.spv", "shaders/mesh.frag.spv");

    var t: f32 = 0;
    var prev = nowNs();

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

        const current = nowNs();
        t += @as(f32, @floatFromInt(current - prev)) / 1e9;
        prev = current;

        renderer.beginFrame() catch |err| {
            std.debug.print("beginFrame error: {}\n", .{err});
            running = false;
            continue;
        };
        renderer.drawMesh(lit_shader, suzanne, rhodo.math.Mat4.rotationY(t));
        renderer.drawMesh(flat_shader, cube, blk: {
            var m = rhodo.math.Mat4.identity;
            m = m.mul(rhodo.math.Mat4.rotationY(-t * 1.3));
            // ponytail: no translation matrix yet. Offset via identity hack.
            m.m[12] = 2.5;
            break :blk m;
        });
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
