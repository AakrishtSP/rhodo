const std = @import("std");

const rhodo = @import("rhodo");

pub fn main() !void {
    try rhodo.renderer.run();
}
