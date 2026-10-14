const std = @import("std");
const sdl = @import("sdl3");
const imgui = @import("imgui.zig").imgui;

// Engine input codes. One variant per key/button/axis games bind. ponytail:
// add a variant + a case in the matching keyCode()/padButtonCode()/axisCode()
// per new binding; mirror SDL's full sets only for free rebinding.
pub const KeyCode = enum {
    // keyboard scancodes
    w, a, s, d, f, g, space, left_shift, escape,
    // gamepad buttons (SDL positional; PS4 = south:cross, east:circle, west:square, north:triangle)
    pad_south, pad_east, pad_west, pad_north,
    pad_dpad_up, pad_dpad_down, pad_dpad_left, pad_dpad_right,
    pad_l1, pad_r1, pad_start,
    // gamepad axes
    axis_left_x, axis_left_y, axis_right_x, axis_right_y,
};

const key_count = @typeInfo(KeyCode).@"enum".fields.len;

// Window-level events. Key/mouse/gamepad input is consumed into Input state,
// not returned — query it with isDown/isJustPressed/axisValue.
pub const Event = union(enum) {
    quit,
    resized,
};

// Polled input state, owned by game code (`var input: rhodo.Input = .{}`).
// beginFrame() clears edges + mouse delta; poll() drains SDL (feeding ImGui
// first), manages the gamepad slot, and folds keys/buttons/axes into state.
// Requires SDL initialized (Renderer.init does it).
pub const Input = struct {
    down: [key_count]bool = .{false} ** key_count,
    pressed: [key_count]bool = .{false} ** key_count,
    released: [key_count]bool = .{false} ** key_count,
    analog: [key_count]f32 = .{0} ** key_count,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,

    // ponytail: one pad only; multi-controller when a game needs player 2.
    gamepad: ?sdl.gamepad.Gamepad = null,
    gamepad_id: ?sdl.joystick.Id = null,

    pub fn deinit(self: *Input) void {
        if (self.gamepad) |g| g.deinit();
        self.gamepad = null;
        self.gamepad_id = null;
    }

    pub fn beginFrame(self: *Input) void {
        self.pressed = .{false} ** key_count;
        self.released = .{false} ** key_count;
        self.mouse_dx = 0;
        self.mouse_dy = 0;
    }

    pub fn poll(self: *Input) ?Event {
        var raw: sdl.c.SDL_Event = undefined;
        while (sdl.c.SDL_PollEvent(&raw)) {
            _ = imgui.Imgui_ProcessEvent(@ptrCast(&raw));
            switch (sdl.events.Event.fromSdl(raw)) {
                .quit, .terminating => return .quit,
                .window_resized => return .resized,
                .key_down => |k| self.setKey(keyCode(k.scancode), true),
                .key_up => |k| self.setKey(keyCode(k.scancode), false),
                .mouse_motion => |m| {
                    self.mouse_dx += m.x_rel;
                    self.mouse_dy += m.y_rel;
                },
                .gamepad_added => |dev| self.openGamepad(dev.id),
                .gamepad_removed => |dev| self.closeGamepad(dev.id),
                .gamepad_axis_motion => |a| {
                    if (!self.isActivePad(a.id)) continue;
                    if (axisCode(a.axis)) |axis| {
                        self.analog[@intFromEnum(axis)] = @as(f32, @floatFromInt(a.value)) / 32767.0;
                    }
                },
                .gamepad_button_down => |b| {
                    if (!self.isActivePad(b.id)) continue;
                    self.setKey(padButtonCode(b.button), true);
                },
                .gamepad_button_up => |b| {
                    if (!self.isActivePad(b.id)) continue;
                    self.setKey(padButtonCode(b.button), false);
                },
                else => continue,
            }
        }
        return null;
    }

    pub fn isDown(self: Input, key: KeyCode) bool {
        return self.down[@intFromEnum(key)];
    }

    pub fn isJustPressed(self: Input, key: KeyCode) bool {
        return self.pressed[@intFromEnum(key)];
    }

    pub fn isJustReleased(self: Input, key: KeyCode) bool {
        return self.released[@intFromEnum(key)];
    }

    // Latest axis value in [-1, 1] (triggers [0, 1]).
    pub fn axisValue(self: Input, axis: KeyCode) f32 {
        return self.analog[@intFromEnum(axis)];
    }

    fn setKey(self: *Input, key: ?KeyCode, down: bool) void {
        const k = key orelse return;
        const i = @intFromEnum(k);
        self.down[i] = down;
        if (down) {
            self.pressed[i] = true;
        } else {
            self.released[i] = true;
        }
    }

    // The slot holds one pad; events from any other connected pad are dropped
    // so a second controller can't drive the same game.
    fn isActivePad(self: *Input, id: sdl.joystick.Id) bool {
        const open = self.gamepad_id orelse return false;
        return open.value == id.value;
    }

    fn openGamepad(self: *Input, id: sdl.joystick.Id) void {
        if (self.gamepad != null) return;
        self.gamepad = sdl.gamepad.Gamepad.init(id) catch |err| {
            std.debug.print("Gamepad open failed: {}\n", .{err});
            return;
        };
        self.gamepad_id = id;
        if (self.gamepad.?.getName()) |name| {
            std.debug.print("Gamepad connected: {s}\n", .{name});
        } else |_| {}
    }

    fn closeGamepad(self: *Input, id: sdl.joystick.Id) void {
        if (!self.isActivePad(id)) return;
        self.gamepad.?.deinit();
        self.gamepad = null;
        self.gamepad_id = null;
    }
};

fn keyCode(scancode: ?sdl.Scancode) ?KeyCode {
    return switch (scancode orelse return null) {
        .w => .w,
        .a => .a,
        .s => .s,
        .d => .d,
        .f => .f,
        .g => .g,
        .space => .space,
        .left_shift => .left_shift,
        .escape => .escape,
        else => null,
    };
}

fn axisCode(axis: sdl.gamepad.Axis) ?KeyCode {
    return switch (axis) {
        .left_x => .axis_left_x,
        .left_y => .axis_left_y,
        .right_x => .axis_right_x,
        .right_y => .axis_right_y,
        else => null,
    };
}

fn padButtonCode(button: sdl.gamepad.Button) ?KeyCode {
    return switch (button) {
        .south => .pad_south,
        .east => .pad_east,
        .west => .pad_west,
        .north => .pad_north,
        .dpad_up => .pad_dpad_up,
        .dpad_down => .pad_dpad_down,
        .dpad_left => .pad_dpad_left,
        .dpad_right => .pad_dpad_right,
        .left_shoulder => .pad_l1,
        .right_shoulder => .pad_r1,
        .start => .pad_start,
        else => null,
    };
}

test "edges latch until beginFrame" {
    var in: Input = .{};
    in.beginFrame();
    in.setKey(.w, true);
    try std.testing.expect(in.isDown(.w));
    try std.testing.expect(in.isJustPressed(.w));
    in.beginFrame();
    try std.testing.expect(in.isDown(.w));
    try std.testing.expect(!in.isJustPressed(.w));
    in.setKey(.w, false);
    try std.testing.expect(!in.isDown(.w));
    try std.testing.expect(in.isJustReleased(.w));
}
