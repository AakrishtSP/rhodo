const std = @import("std");
const sdl = @import("sdl3");

pub const SoundHandle = u32;

// Procedural SFX: no files, no mixer, no music. Three short mono blips
// generated at init, queued to the default playback stream on play().
// Infallible init — if no audio device exists it logs and stays silent so the
// app never dies for lack of speakers. Per-entity voices arrive with the
// second enemy type (one box type needs no distinction yet).
pub const Audio = struct {
    stream: ?sdl.audio.Stream = null,
    // 22050Hz S16 mono, 0.25s max each. Fixed buffers, no allocator.
    click: [5512]i16 = undefined,
    click_len: usize = 0,
    pop: [5512]i16 = undefined,
    pop_len: usize = 0,
    thud: [5512]i16 = undefined,
    thud_len: usize = 0,

    pub const click_handle: SoundHandle = 0;
    pub const pop_handle: SoundHandle = 1;
    pub const thud_handle: SoundHandle = 2;

    pub fn init() Audio {
        var self = Audio{};
        const spec = sdl.audio.Spec{
            .format = .signed_16_bit,
            .num_channels = 1,
            .sample_rate = 22050,
        };
        const stream = sdl.audio.Device.default_playback.openStream(spec, void, null, null) catch |err| {
            std.debug.print("Audio disabled (no device): {}\n", .{err});
            return self;
        };
        stream.resumeDevice() catch |err| {
            std.debug.print("Audio disabled (resume failed): {}\n", .{err});
            stream.deinit();
            return self;
        };
        self.stream = stream;
        self.click_len = self.genClick();
        self.pop_len = self.genPop();
        self.thud_len = self.genThud();
        return self;
    }

    pub fn deinit(self: *Audio) void {
        if (self.stream) |s| s.deinit();
        self.stream = null;
    }

    pub fn play(self: *Audio, handle: SoundHandle) void {
        const s = self.stream orelse return;
        const clip: []const i16 = switch (handle) {
            click_handle => self.click[0..self.click_len],
            pop_handle => self.pop[0..self.pop_len],
            thud_handle => self.thud[0..self.thud_len],
            else => return,
        };
        s.putData(std.mem.sliceAsBytes(clip)) catch {};
    }

    // 30ms noise burst, exponential decay.
    fn genClick(self: *Audio) usize {
        var seed: u32 = 0x12345678;
        const n = 660;
        for (0..n) |i| {
            seed = seed *% 1664525 +% 1013904223;
            const noise: f32 = @as(f32, @floatFromInt(@as(i32, @bitCast(seed >> 9)))) / 2147483648.0;
            const env = @exp(-@as(f32, @floatFromInt(i)) / 120.0);
            self.click[i] = @intFromFloat(noise * env * 20000.0);
        }
        return n;
    }

    // 120ms sine sweep 600Hz down to 200Hz, decayed.
    fn genPop(self: *Audio) usize {
        const n = 2640;
        for (0..n) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / 22050.0;
            const f = 600.0 - 400.0 * @as(f32, @floatFromInt(i)) / @as(f32, n);
            const env = @exp(-t * 25.0);
            self.pop[i] = @intFromFloat(@sin(2.0 * std.math.pi * f * t) * env * 20000.0);
        }
        return n;
    }

    // 200ms low sine 110Hz down to 45Hz, slow decay.
    fn genThud(self: *Audio) usize {
        const n = 4400;
        for (0..n) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / 22050.0;
            const f = 110.0 - 65.0 * @as(f32, @floatFromInt(i)) / @as(f32, n);
            const env = @exp(-t * 12.0);
            self.thud[i] = @intFromFloat(@sin(2.0 * std.math.pi * f * t) * env * 24000.0);
        }
        return n;
    }
};
