const std = @import("std");

const rhodo = @import("rhodo");

pub fn main(init: std.process.Init) !void {
    try rhodo.renderer.run(init.io);
}
