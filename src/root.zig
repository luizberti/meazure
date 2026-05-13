//! # meazure

const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) {
        @compileError("meazure currently supports x86_64 Linux only");
    }
}

pub const perf = @import("perf.zig");
pub const Clock = @import("Clock.zig");
