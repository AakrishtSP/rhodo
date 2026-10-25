const std = @import("std");
const sdl = @import("sdl3");
const imgui = @import("imgui.zig").imgui;

// Full input enums are re-exported from SDL instead of mirrored by hand: the
// sets are large, sparse, and grow with SDL. This bends the "no sdl types in
// the public API" rule for these four enums only — game code still never
// imports sdl3 itself.
pub const Key = sdl.Scancode;
pub const MouseButton = sdl.mouse.Button;
pub const PadButton = sdl.gamepad.Button;
pub const PadAxis = sdl.gamepad.Axis;

const key_count = maxTag(Key) + 1;
// SDL reports a u8 button index and only names the five standard buttons.
// Track the whole range so X1/X2 and extra vendor buttons never alias or panic.
const mouse_count = 256;
const button_count = maxTag(PadButton) + 1;
const axis_count = maxTag(PadAxis) + 1;

fn maxTag(comptime E: type) usize {
    var max: usize = 0;
    for (@typeInfo(E).@"enum".field_values) |v| max = @max(max, @as(usize, @intCast(v)));
    return max;
}

fn idx(x: anytype) usize {
    return @intCast(@backingInt(x));
}

// Window-level events. Key/mouse/gamepad input is consumed into Input state,
// not returned — query it with isPressed/isJustPressed/action queries.
pub const Event = union(enum) {
    quit,
    resized,
};

/// One physical control that can drive an action.
pub const Binding = union(enum) {
    key: Key,
    /// Standard buttons are `.left`, `.middle`, `.right`, `.x1`, `.x2`;
    /// `.x1`/`.x2` are the side buttons. Higher vendor indices also work.
    mouse_button: MouseButton,
    pad_button: PadButton,
    /// Stick axis read as a digital direction: `dir` -1 (negative side, e.g.
    /// stick up) or 1 (positive side). Triggers only ever push positive.
    pad_axis: struct { axis: PadAxis, dir: f32 = 1 },
};

/// Flattened action row (name + controls); built from the game's comptime map.
const Action = struct {
    name: []const u8,
    bindings: []const Binding,
};

/// Per-device gates applied to *action* queries only (raw key/axis/mouse
/// queries always see everything). A game with a UI sets `.keyboard = captured`
/// so keys and mouse buttons don't drive the world while a text field or ImGui
/// window has focus; mouse capture is toggled with the same gate.
pub const Devices = packed struct {
    keyboard: bool = true,
    pad: bool = true,
};

// Polled input state, owned by game code (`var input: rhodo.Input = .{}`).
// beginFrame() clears edges + mouse delta, poll() drains SDL (feeding ImGui
// first), manages the gamepad slot, and folds keys/mouse buttons/pad
// buttons/axes into state. Requires SDL initialized (Renderer.init does it).
pub const Input = struct {
    key_down: [key_count]bool = @splat(false),
    key_pressed: [key_count]bool = @splat(false),
    key_released: [key_count]bool = @splat(false),
    /// OS auto-repeat landed on this frame (held key "just pressed" again).
    key_repeated: [key_count]bool = @splat(false),

    mouse_down: [mouse_count]bool = @splat(false),
    mouse_pressed: [mouse_count]bool = @splat(false),
    mouse_released: [mouse_count]bool = @splat(false),

    btn_down: [button_count]bool = @splat(false),
    btn_pressed: [button_count]bool = @splat(false),
    btn_released: [button_count]bool = @splat(false),

    axes: [axis_count]f32 = @splat(0),
    /// Axis values as of the end of last frame, for analog edge detection.
    axes_prev: [axis_count]f32 = @splat(0),

    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,

    /// Stick center wobble threshold, rescaled out of the output. Real pads
    /// drift a few percent; 0.25 is safe but wasteful travel — tune per game.
    deadzone: f32 = 0.25,

    devices: Devices = .{},

    // ponytail: setMap keeps the game's table by reference (comptime const in
    // practice); copy it if actions are ever built at runtime.
    actions: []const Action = &.{},

    // ponytail: one pad only; multi-controller when a game needs player 2.
    gamepad: ?sdl.gamepad.Gamepad = null,
    gamepad_id: ?sdl.joystick.Id = null,

    pub fn deinit(self: *Input) void {
        if (self.gamepad) |g| g.deinit();
        self.gamepad = null;
        self.gamepad_id = null;
    }

    /// Map actions to controls. `map` is a comptime struct whose field names are
    /// the action names:
    ///
    /// ```zig
    /// const actions = .{
    ///     .move_forward = &[_]rhodo.Binding{ .{ .key = .w } },
    /// };
    /// input.setMap(actions);
    /// ```
    pub fn setMap(self: *Input, comptime map: anytype) void {
        const names = @typeInfo(@TypeOf(map)).@"struct".field_names;
        const table = comptime blk: {
            var rows: [names.len]Action = undefined;
            for (names, 0..) |name, i| rows[i] = .{ .name = name, .bindings = @field(map, name) };
            break :blk rows;
        };
        self.actions = &table;
    }

    pub fn beginFrame(self: *Input) void {
        self.key_pressed = @splat(false);
        self.key_released = @splat(false);
        self.key_repeated = @splat(false);
        self.mouse_pressed = @splat(false);
        self.mouse_released = @splat(false);
        self.btn_pressed = @splat(false);
        self.btn_released = @splat(false);
        self.axes_prev = self.axes;
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
                // Losing focus never delivers the matching key_up, so held
                // keys would stick forever. Drop everything; replaying state
                // is the OS's job (SDL re-sends focus/key events on regain).
                .window_focus_lost => self.clearAll(),
                .key_down => |k| if (k.scancode) |key|
                    self.setKey(key, if (k.repeat) .repeat else .press),
                .key_up => |k| if (k.scancode) |key|
                    self.setKey(key, .release),
                .mouse_motion => |m| {
                    self.mouse_dx += m.x_rel;
                    self.mouse_dy += m.y_rel;
                },
                .mouse_button_down => |m| self.setMouseButton(m.button, true),
                .mouse_button_up => |m| self.setMouseButton(m.button, false),
                .gamepad_added => |dev| self.openGamepad(dev.id),
                .gamepad_removed => |dev| self.closeGamepad(dev.id),
                .gamepad_axis_motion => |a| {
                    if (!self.isActivePad(a.id)) continue;
                    self.axes[idx(a.axis)] = clampAxis(@as(f32, @floatFromInt(a.value)) / 32767.0);
                },
                .gamepad_button_down => |b| if (self.isActivePad(b.id)) self.setButton(b.button, true),
                .gamepad_button_up => |b| if (self.isActivePad(b.id)) self.setButton(b.button, false),
                else => continue,
            }
        }
        return null;
    }

    // --- raw queries -------------------------------------------------------

    /// Held down right now.
    pub fn isPressed(self: Input, key: Key) bool {
        return self.key_down[idx(key)];
    }

    /// First frame of a press. OS auto-repeat does not count — use isRepeated.
    pub fn isJustPressed(self: Input, key: Key) bool {
        return self.key_pressed[idx(key)];
    }

    pub fn isJustReleased(self: Input, key: Key) bool {
        return self.key_released[idx(key)];
    }

    /// The OS repeated this held key on this frame (keyboard only).
    pub fn isRepeated(self: Input, key: Key) bool {
        return self.key_repeated[idx(key)];
    }

    /// Held down right now (raw; ignores `devices`). Includes `.x1`/`.x2`
    /// side buttons and any higher vendor button index.
    pub fn isMousePressed(self: Input, button: MouseButton) bool {
        return self.mouse_down[idx(button)];
    }

    /// First frame of a mouse press. Mouse buttons do not auto-repeat.
    pub fn isMouseJustPressed(self: Input, button: MouseButton) bool {
        return self.mouse_pressed[idx(button)];
    }

    pub fn isMouseJustReleased(self: Input, button: MouseButton) bool {
        return self.mouse_released[idx(button)];
    }

    /// Raw axis in [-1, 1] (triggers [0, 1]).
    pub fn axisValue(self: Input, axis: PadAxis) f32 {
        return self.axes[idx(axis)];
    }

    /// Axis with the deadzone removed and the remainder rescaled to [-1, 1],
    /// signed. This is what analog camera/movement should read.
    pub fn axisStrength(self: Input, axis: PadAxis) f32 {
        return deadzoned(self.axes[idx(axis)], self.deadzone);
    }

    // --- action queries (Godot's Input.is_action_*) ------------------------
    // The action can be a string ("move_forward") or an enum / enum literal
    // (.move_forward); the mapped name is the same either way.

    pub fn isActionPressed(self: Input, action: anytype) bool {
        for (self.find(actionName(action)).bindings) |b| {
            if (self.bindingActive(b)) return true;
        }
        return false;
    }

    pub fn isActionJustPressed(self: Input, action: anytype) bool {
        for (self.find(actionName(action)).bindings) |b| {
            if (self.bindingJustPressed(b)) return true;
        }
        return false;
    }

    pub fn isActionJustReleased(self: Input, action: anytype) bool {
        for (self.find(actionName(action)).bindings) |b| {
            if (self.bindingJustReleased(b)) return true;
        }
        return false;
    }

    /// Keyboard auto-repeat on any binding. Mouse and pad buttons don't repeat.
    pub fn isActionRepeated(self: Input, action: anytype) bool {
        if (!self.devices.keyboard) return false;
        for (self.find(actionName(action)).bindings) |b| switch (b) {
            .key => |k| if (self.key_repeated[idx(k)]) return true,
            else => {},
        };
        return false;
    }

    /// Analog pressure with digital bindings reading 1.0: max over bindings.
    pub fn actionStrength(self: Input, action: anytype) f32 {
        var strength: f32 = 0;
        for (self.find(actionName(action)).bindings) |b| strength = @max(strength, self.bindingStrength(b));
        return strength;
    }

    // --- internals ---------------------------------------------------------

    fn find(self: Input, name: []const u8) Action {
        for (self.actions) |a| {
            if (std.mem.eql(u8, a.name, name)) return a;
        }
        std.debug.assert(false); // unmapped action name (typo?)
        return .{ .name = name, .bindings = &.{} };
    }

    fn bindingActive(self: Input, b: Binding) bool {
        return switch (b) {
            .key => |k| self.devices.keyboard and self.key_down[idx(k)],
            .mouse_button => |btn| self.devices.keyboard and self.mouse_down[idx(btn)],
            .pad_button => |btn| self.devices.pad and self.btn_down[idx(btn)],
            .pad_axis => |a| self.devices.pad and self.axisDirActive(a),
        };
    }

    fn bindingJustPressed(self: Input, b: Binding) bool {
        return switch (b) {
            .key => |k| self.devices.keyboard and self.key_pressed[idx(k)],
            .mouse_button => |btn| self.devices.keyboard and self.mouse_pressed[idx(btn)],
            .pad_button => |btn| self.devices.pad and self.btn_pressed[idx(btn)],
            .pad_axis => |a| self.devices.pad and self.axisDirActive(a) and !self.axisDirActivePrev(a),
        };
    }

    fn bindingJustReleased(self: Input, b: Binding) bool {
        return switch (b) {
            .key => |k| self.devices.keyboard and self.key_released[idx(k)],
            .mouse_button => |btn| self.devices.keyboard and self.mouse_released[idx(btn)],
            .pad_button => |btn| self.devices.pad and self.btn_released[idx(btn)],
            .pad_axis => |a| self.devices.pad and !self.axisDirActive(a) and self.axisDirActivePrev(a),
        };
    }

    fn bindingStrength(self: Input, b: Binding) f32 {
        return switch (b) {
            .key => |k| if (self.devices.keyboard and self.key_down[idx(k)]) 1 else 0,
            .mouse_button => |btn| if (self.devices.keyboard and self.mouse_down[idx(btn)]) 1 else 0,
            .pad_button => |btn| if (self.devices.pad and self.btn_down[idx(btn)]) 1 else 0,
            .pad_axis => |a| blk: {
                if (!self.devices.pad) break :blk 0;
                const signed = self.axisStrength(a.axis) * a.dir;
                break :blk if (signed > 0) signed else 0;
            },
        };
    }

    fn axisDirActive(self: Input, a: anytype) bool {
        return self.bindingAxisStrength(a) != 0;
    }

    fn axisDirActivePrev(self: Input, a: anytype) bool {
        return self.bindingAxisStrengthPrev(a) != 0;
    }

    fn bindingAxisStrength(self: Input, a: anytype) f32 {
        return self.axisStrength(a.axis) * a.dir;
    }

    fn bindingAxisStrengthPrev(self: Input, a: anytype) f32 {
        return deadzoned(self.axes_prev[idx(a.axis)], self.deadzone) * a.dir;
    }

    const KeyEvent = enum { press, repeat, release };

    fn setKey(self: *Input, key: Key, ev: KeyEvent) void {
        const i = idx(key);
        switch (ev) {
            .press => if (!self.key_down[i]) {
                self.key_down[i] = true;
                self.key_pressed[i] = true;
            },
            .repeat => {
                self.key_down[i] = true;
                self.key_repeated[i] = true;
            },
            .release => if (self.key_down[i]) {
                self.key_down[i] = false;
                self.key_released[i] = true;
            },
        }
    }

    fn setButton(self: *Input, button: PadButton, down: bool) void {
        const i = idx(button);
        if (self.btn_down[i] == down) return;
        self.btn_down[i] = down;
        if (down) self.btn_pressed[i] = true else self.btn_released[i] = true;
    }

    fn setMouseButton(self: *Input, button: MouseButton, down: bool) void {
        const i = idx(button);
        if (self.mouse_down[i] == down) return;
        self.mouse_down[i] = down;
        if (down) self.mouse_pressed[i] = true else self.mouse_released[i] = true;
    }

    fn clearAll(self: *Input) void {
        self.key_down = @splat(false);
        self.key_pressed = @splat(false);
        self.key_released = @splat(false);
        self.key_repeated = @splat(false);
        self.mouse_down = @splat(false);
        self.mouse_pressed = @splat(false);
        self.mouse_released = @splat(false);
        self.btn_down = @splat(false);
        self.btn_pressed = @splat(false);
        self.btn_released = @splat(false);
        self.axes = @splat(0);
        self.axes_prev = @splat(0);
        self.mouse_dx = 0;
        self.mouse_dy = 0;
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
        // No release events arrive after unplug; drop the pad's state so
        // held buttons/axes don't drive the game forever.
        self.btn_down = @splat(false);
        self.axes = @splat(0);
        self.axes_prev = @splat(0);
    }

    fn isActivePad(self: *Input, id: sdl.joystick.Id) bool {
        const open = self.gamepad_id orelse return false;
        return open.value == id.value;
    }
};

fn deadzoned(v: f32, deadzone: f32) f32 {
    const d = @min(deadzone, 0.9);
    if (@abs(v) <= d) return 0;
    return (v - std.math.sign(v) * d) / (1.0 - d);
}

/// Mapped name behind an action reference: string, enum, or enum literal.
fn actionName(action: anytype) []const u8 {
    const T = @TypeOf(action);
    return switch (@typeInfo(T)) {
        .enum_literal => @tagName(action),
        .@"enum" => std.enums.tagName(T, action) orelse "?",
        .pointer, .array => action,
        else => @compileError("action must be a string, enum or enum literal, got " ++ @typeName(T)),
    };
}

fn clampAxis(v: f32) f32 {
    return std.math.clamp(v, -1.0, 1.0);
}

// --- tests -----------------------------------------------------------------

fn press(in: *Input, key: Key) void {
    in.setKey(key, .press);
}

fn release(in: *Input, key: Key) void {
    in.setKey(key, .release);
}

test "edges latch until beginFrame" {
    var in: Input = .{};
    in.beginFrame();
    press(&in, .w);
    try std.testing.expect(in.isPressed(.w));
    try std.testing.expect(in.isJustPressed(.w));
    in.beginFrame();
    try std.testing.expect(in.isPressed(.w));
    try std.testing.expect(!in.isJustPressed(.w));
    release(&in, .w);
    try std.testing.expect(!in.isPressed(.w));
    try std.testing.expect(in.isJustReleased(.w));
}

test "auto-repeat never re-fires justPressed" {
    var in: Input = .{};
    in.beginFrame();
    press(&in, .g);
    try std.testing.expect(in.isJustPressed(.g));
    in.beginFrame();
    in.setKey(.g, .repeat);
    try std.testing.expect(in.isRepeated(.g));
    try std.testing.expect(!in.isJustPressed(.g));
    try std.testing.expect(in.isPressed(.g));
}

test "duplicate key_down is not a new edge" {
    var in: Input = .{};
    in.beginFrame();
    press(&in, .w);
    in.beginFrame();
    press(&in, .w);
    try std.testing.expect(!in.isJustPressed(.w));
}

test "all standard mouse buttons are independent" {
    const buttons = [_]MouseButton{ .left, .middle, .right, .x1, .x2 };
    var in: Input = .{};
    in.beginFrame();
    for (buttons) |b| in.setMouseButton(b, true);
    for (buttons) |b| {
        try std.testing.expect(in.isMousePressed(b));
        try std.testing.expect(in.isMouseJustPressed(b));
    }

    in.setMouseButton(.x1, false);
    try std.testing.expect(!in.isMousePressed(.x1));
    try std.testing.expect(in.isMouseJustReleased(.x1));
    for ([_]MouseButton{ .left, .middle, .right, .x2 }) |b| {
        try std.testing.expect(in.isMousePressed(b));
    }
}

test "mouse buttons beyond the standard five are tracked" {
    var in: Input = .{};
    in.beginFrame();
    const extra: MouseButton = @fromBackingInt(@intCast(200));
    in.setMouseButton(extra, true);
    try std.testing.expect(in.isMousePressed(extra));
    try std.testing.expect(in.isMouseJustPressed(extra));

    in.beginFrame();
    try std.testing.expect(!in.isMouseJustPressed(extra));
    in.setMouseButton(extra, false);
    try std.testing.expect(in.isMouseJustReleased(extra));
}

test "duplicate mouse down is not a new edge" {
    var in: Input = .{};
    in.beginFrame();
    in.setMouseButton(.left, true);
    in.beginFrame();
    in.setMouseButton(.left, true);
    try std.testing.expect(!in.isMouseJustPressed(.left));
}

test "mouse actions by name, side buttons, and device gate" {
    const map = .{
        .attack = &[_]Binding{.{ .mouse_button = .left }},
        .parry = &[_]Binding{.{ .mouse_button = .x1 }},
    };

    var in: Input = .{};
    in.setMap(map);
    in.beginFrame();
    in.setMouseButton(.left, true);
    try std.testing.expect(in.isActionPressed("attack"));
    try std.testing.expect(in.isActionJustPressed(.attack));
    try std.testing.expectEqual(@as(f32, 1), in.actionStrength(.attack));

    in.devices.keyboard = false;
    try std.testing.expect(!in.isActionPressed("attack"));
    in.devices.keyboard = true;

    in.beginFrame();
    try std.testing.expect(in.isActionPressed("attack"));
    try std.testing.expect(!in.isActionJustPressed("attack"));

    in.setMouseButton(.x1, true);
    try std.testing.expect(in.isActionJustPressed(.parry));
    try std.testing.expect(in.isActionPressed("parry"));

    in.setMouseButton(.left, false);
    try std.testing.expect(in.isActionJustReleased("attack"));
    try std.testing.expect(!in.isActionPressed("attack"));
}

test "focus loss clears held state" {
    var in: Input = .{};
    in.beginFrame();
    press(&in, .w);
    in.setMouseButton(.right, true);
    in.mouse_dx = 10;
    in.axes[idx(PadAxis.left_x)] = 0.9;
    in.clearAll();
    try std.testing.expect(!in.isPressed(.w));
    try std.testing.expect(!in.isMousePressed(.right));
    try std.testing.expectEqual(@as(f32, 0), in.axisValue(PadAxis.left_x));
    try std.testing.expectEqual(@as(f32, 0), in.mouse_dx);
}

test "actions by name: keys, axes, device gates" {
    const map = .{
        .move_forward = &[_]Binding{
            .{ .key = .w },
            .{ .pad_axis = .{ .axis = .left_y, .dir = -1 } },
        },
    };

    var in: Input = .{};
    in.setMap(map);

    // keyboard
    in.beginFrame();
    press(&in, .w);
    try std.testing.expect(in.isActionPressed("move_forward")); // string form
    try std.testing.expect(in.isActionJustPressed(.move_forward)); // enum literal
    try std.testing.expectEqual(@as(f32, 1), in.actionStrength(.move_forward));

    // typed enum value reads the same name
    const Move = enum { move_forward };
    try std.testing.expect(in.isActionPressed(Move.move_forward));

    in.devices.keyboard = false;
    try std.testing.expect(!in.isActionPressed("move_forward"));
    in.devices.keyboard = true;

    // drifted stick inside the deadzone must not trigger the action (release
    // the key first: physical key state persists across frames)
    in.beginFrame();
    release(&in, .w);
    in.axes[idx(PadAxis.left_y)] = -0.1;
    try std.testing.expect(!in.isActionPressed("move_forward"));

    // stick up: prev frame at rest, this frame pushed (negative = up)
    in.beginFrame();
    in.axes[idx(PadAxis.left_y)] = -1.0;
    try std.testing.expect(in.isActionJustPressed("move_forward"));
    try std.testing.expectApproxEqAbs(@as(f32, 1), in.actionStrength("move_forward"), 1e-6);

    // next frame still held: pressed edge gone
    in.beginFrame();
    try std.testing.expect(in.isActionPressed("move_forward"));
    try std.testing.expect(!in.isActionJustPressed("move_forward"));

    // released back to center
    in.beginFrame();
    in.axes[idx(PadAxis.left_y)] = 0;
    try std.testing.expect(in.isActionJustReleased("move_forward"));
}

test "deadzone rescales and zeroes the center" {
    try std.testing.expectEqual(@as(f32, 0), deadzoned(0.1, 0.25));
    try std.testing.expectEqual(@as(f32, 0), deadzoned(0.25, 0.25));
    try std.testing.expectApproxEqAbs(@as(f32, 1), deadzoned(1.0, 0.25), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), deadzoned(-1.0, 0.25), 1e-6);
}
