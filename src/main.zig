const std = @import("std");
const meazure = @import("meazure");

const SAMPLES = 16;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("meazure smoke test\n", .{});

    const status: []const u8 = if (meazure.Clock.setup(io, gpa)) |_| "bypass active" else |_| "system fallback";
    try out.print("realtime: {s}\n", .{status});

    var t = meazure.Clock.init();
    try out.print("clock: {any}\n\n", .{t});
    try out.print("{s:>20} {s:>14}\n", .{ "now_ns", "elapsed_ns" });
    for (0..SAMPLES) |_| {
        t.refresh();
        const wall = t.now();
        const inst = meazure.Clock.instant();
        burn(1000);
        const span = t.elapsed(inst);
        try out.print("{d:>20} {d:>14}\n", .{ wall, span });
    }
}

/// Collatz synthetic workload
fn burn(fuel: u64) void {
    var r = fuel;
    for (0..fuel) |_| r = if (r & 1 == 1) 3 *% r + 1 else r / 2;
    std.mem.doNotOptimizeAway(r);
}
