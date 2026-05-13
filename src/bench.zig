//! Microbenchmark of `TSCClock` + `Io.Clock` baseline. Reports:
//! 1. Percentile table with jitter threshold p50+5ns.
//! 2. L1D read-miss summary via `rdpmc`. Skipped if perf_event_open /
//!    rdpmc isn't available (set MEAZURE_NO_PERF to force-skip).
//! 3. Bucketed histogram.
//! 4. Per-sample CSV dump if `MEAZURE_CSV=path` is set in the env.
//!
//! Pin with `taskset -c N` for stable tails. Strategy selection is
//! controlled by `realtime.setup`. Set MEAZURE_NO_VVAR=1 to skip it and
//! benchmark the clock_gettime fallback.

const std = @import("std");
const builtin = @import("builtin");
const meazure = @import("meazure");

inline fn rdtscp() u64 {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtscp"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
                :
                : .{ .ecx = true });
            break :blk (@as(u64, hi) << 32) | @as(u64, lo);
        },
        else => unreachable,
    };
}

const N_RUNS: usize = 100_001;
const N_BENCH: usize = 100;

/// Anything above p50 + this many ns is jitter: scheduling noise,
/// interrupts, anything that perturbs the inner loop.
const JITTER_DELTA_NS: u64 = 5;

const Sample = struct {
    ts_ns: u64,
    dur_ns: u64,
    l1_misses: u64,
};

const Bench = struct {
    name: []const u8,
    samples: []Sample,
};

const bucket_edges = [_]u64{ 40, 45, 50, 60, 70, 100, 200 };
const bucket_labels = [_][]const u8{ "<40", "40-44", "45-49", "50-59", "60-69", "70-99", "100-199", ">=200" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const skip_vvar = init.environ_map.get("MEAZURE_NO_VVAR") != null;
    const status: []const u8 = if (!skip_vvar)
        (if (meazure.Clock.setup(io, gpa)) |_| "vvar bypass active" else |_| "system fallback")
    else
        "system fallback";
    try out.print("realtime: {s}\n\n", .{status});

    const conv = meazure.Clock.init();
    var t = meazure.Clock.init();

    const skip_perf = init.environ_map.get("MEAZURE_NO_PERF") != null;
    var counter_opt: ?meazure.perf.L1dMissCounter = null;
    defer if (counter_opt) |*c| c.deinit();
    if (!skip_perf) {
        counter_opt = meazure.perf.L1dMissCounter.init() catch |err| blk: {
            try out.print("perf: L1D miss counter unavailable ({t}); continuing without it.\n", .{err});
            try out.print("      try: sudo setcap cap_perfmon=ep ./zig-out/bin/meazure-bench\n", .{});
            try out.print("       or: sudo sysctl -w kernel.perf_event_paranoid=1\n\n", .{});
            break :blk null;
        };
    }

    const cache_samples = try gpa.alloc(Sample, N_RUNS);
    defer gpa.free(cache_samples);
    const io_samples = try gpa.alloc(Sample, N_RUNS);
    defer gpa.free(io_samples);
    const refresh_samples = try gpa.alloc(Sample, N_RUNS);
    defer gpa.free(refresh_samples);

    runCached(&t, cache_samples, conv, counter_opt);
    runIo(io_samples, conv, io, counter_opt);
    runRefresh(&t, refresh_samples, conv, counter_opt);

    const benches = [_]Bench{
        .{ .name = "cache", .samples = cache_samples },
        .{ .name = "io_naive", .samples = io_samples },
        .{ .name = "refresh", .samples = refresh_samples },
    };

    const scratch = try gpa.alloc(u64, N_RUNS);
    defer gpa.free(scratch);

    try out.print("durations (per-call ns):\n", .{});
    try out.print(
        "  {s:12}  {s:>5}  {s:>5}  {s:>5}  {s:>5}  {s:>5}  {s:>5}  {s:>6}  {s:>9}\n",
        .{ "timer", "min", "p50", "p90", "p99", "p99.9", "max", "jitter", "jitter_dt" },
    );
    for (benches) |b| try reportPercentiles(b, scratch, out);

    if (counter_opt != null) {
        try out.print("\nL1D read-miss counts per outer run (each run is {d} inner iters):\n", .{N_BENCH});
        try out.print("  {s:12}  {s:>8}  {s:>8}  {s:>8}  {s:>8}  {s:>8}  {s:>8}\n", .{ "timer", "min", "p50", "p90", "p99", "max", "runs>=1" });
        for (benches) |b| try reportMisses(b, scratch, out);
    }

    try out.print("\nbucket counts (per-call ns):\n", .{});
    try out.print("  {s:12}", .{""});
    for (bucket_labels) |lbl| try out.print("  {s:>7}", .{lbl});
    try out.print("\n", .{});
    for (benches) |b| try reportHistogram(b, out);

    if (init.environ_map.get("MEAZURE_CSV")) |csv_path| {
        try dumpCsv(csv_path, &benches, io);
        try out.print("\nwrote per-sample CSV to {s}\n", .{csv_path});
    }
}

fn runCached(
    clk: *meazure.Clock,
    samples: []Sample,
    conv: meazure.Clock,
    counter_opt: ?meazure.perf.L1dMissCounter,
) void {
    for (0..N_BENCH) |_| {
        const cp = meazure.Clock.instant();
        std.mem.doNotOptimizeAway(cp);
        const e = clk.elapsed(cp);
        std.mem.doNotOptimizeAway(e);
    }

    const bench_start = rdtscp();
    for (samples) |*slot| {
        const m0: u64 = if (counter_opt) |c| c.read() else 0;
        const t0 = rdtscp();
        var i: usize = 0;
        while (i < N_BENCH) : (i += 1) {
            const cp = meazure.Clock.instant();
            std.mem.doNotOptimizeAway(cp);
            const e = clk.elapsed(cp);
            std.mem.doNotOptimizeAway(e);
        }
        const t1 = rdtscp();
        const m1: u64 = if (counter_opt) |c| c.read() else 0;
        slot.* = .{
            .ts_ns = conv.timespan(t0 -% bench_start),
            .dur_ns = conv.timespan(t1 -% t0) / N_BENCH,
            .l1_misses = m1 -% m0,
        };
    }
}

fn runRefresh(
    clk: *meazure.Clock,
    samples: []Sample,
    conv: meazure.Clock,
    counter_opt: ?meazure.perf.L1dMissCounter,
) void {
    for (0..N_BENCH) |_| {
        clk.refresh();
        std.mem.doNotOptimizeAway(clk);
    }

    const bench_start = rdtscp();
    for (samples) |*slot| {
        const m0: u64 = if (counter_opt) |c| c.read() else 0;
        const t0 = rdtscp();
        var i: usize = 0;
        while (i < N_BENCH) : (i += 1) {
            clk.refresh();
            std.mem.doNotOptimizeAway(clk);
        }
        const t1 = rdtscp();
        const m1: u64 = if (counter_opt) |c| c.read() else 0;
        slot.* = .{
            .ts_ns = conv.timespan(t0 -% bench_start),
            .dur_ns = conv.timespan(t1 -% t0) / N_BENCH,
            .l1_misses = m1 -% m0,
        };
    }
}

fn runIo(
    samples: []Sample,
    conv: meazure.Clock,
    io: std.Io,
    counter_opt: ?meazure.perf.L1dMissCounter,
) void {
    for (0..N_BENCH) |_| {
        const ts = std.Io.Clock.Timestamp.now(io, .boot);
        const dur = ts.untilNow(io);
        std.mem.doNotOptimizeAway(@as(i64, @truncate(dur.raw.nanoseconds)));
    }

    const bench_start = rdtscp();
    for (samples) |*slot| {
        const m0: u64 = if (counter_opt) |c| c.read() else 0;
        const t0 = rdtscp();
        var i: usize = 0;
        while (i < N_BENCH) : (i += 1) {
            const ts = std.Io.Clock.Timestamp.now(io, .boot);
            const dur = ts.untilNow(io);
            std.mem.doNotOptimizeAway(@as(i64, @truncate(dur.raw.nanoseconds)));
        }
        const t1 = rdtscp();
        const m1: u64 = if (counter_opt) |c| c.read() else 0;
        slot.* = .{
            .ts_ns = conv.timespan(t0 -% bench_start),
            .dur_ns = conv.timespan(t1 -% t0) / N_BENCH,
            .l1_misses = m1 -% m0,
        };
    }
}

fn percentile(sorted: []const u64, num: usize, den: usize) u64 {
    if (sorted.len == 0) return 0;
    const idx = (sorted.len * num) / den;
    return sorted[@min(idx, sorted.len - 1)];
}

fn reportPercentiles(b: Bench, scratch: []u64, out: *std.Io.Writer) !void {
    for (b.samples, 0..) |s, i| scratch[i] = s.dur_ns;
    std.mem.sort(u64, scratch, {}, std.sort.asc(u64));

    const min = scratch[0];
    const p50 = percentile(scratch, 50, 100);
    const p90 = percentile(scratch, 90, 100);
    const p99 = percentile(scratch, 99, 100);
    const p999 = percentile(scratch, 999, 1000);
    const max = scratch[scratch.len - 1];

    const jitter = countAndInterval(b.samples, p50 + JITTER_DELTA_NS);

    try out.print(
        "  {s:12}  {d:>3}ns  {d:>3}ns  {d:>3}ns  {d:>3}ns  {d:>3}ns  {d:>3}ns  {d:>6}  ",
        .{ b.name, min, p50, p90, p99, p999, max, jitter.count },
    );
    try printInterval(out, jitter, 9);
    try out.print("\n", .{});
}

const CountAndInterval = struct {
    count: usize,
    mean_dt_ns: u64,
};

fn countAndInterval(samples: []const Sample, threshold: u64) CountAndInterval {
    var count: usize = 0;
    var first_ts: u64 = 0;
    var last_ts: u64 = 0;
    for (samples) |s| {
        if (s.dur_ns > threshold) {
            if (count == 0) first_ts = s.ts_ns;
            last_ts = s.ts_ns;
            count += 1;
        }
    }
    const dt = if (count >= 2) (last_ts - first_ts) / (count - 1) else 0;
    return .{ .count = count, .mean_dt_ns = dt };
}

fn printInterval(out: *std.Io.Writer, ci: CountAndInterval, width: usize) !void {
    if (ci.count < 2) {
        try out.splatByteAll(' ', width - 1);
        try out.print("-", .{});
        return;
    }
    if (ci.mean_dt_ns >= 1_000_000) {
        try out.print("{d:>5}.{d:0>1}ms", .{ ci.mean_dt_ns / 1_000_000, (ci.mean_dt_ns % 1_000_000) / 100_000 });
    } else if (ci.mean_dt_ns >= 1_000) {
        try out.print("{d:>5}.{d:0>1}us", .{ ci.mean_dt_ns / 1_000, (ci.mean_dt_ns % 1_000) / 100 });
    } else {
        try out.print("{d:>6}ns", .{ci.mean_dt_ns});
    }
}

fn reportMisses(b: Bench, scratch: []u64, out: *std.Io.Writer) !void {
    for (b.samples, 0..) |s, i| scratch[i] = s.l1_misses;
    std.mem.sort(u64, scratch, {}, std.sort.asc(u64));

    var any_miss: usize = 0;
    for (b.samples) |s| {
        if (s.l1_misses > 0) any_miss += 1;
    }

    try out.print(
        "  {s:12}  {d:>8}  {d:>8}  {d:>8}  {d:>8}  {d:>8}  {d:>8}\n",
        .{
            b.name,
            scratch[0],
            percentile(scratch, 50, 100),
            percentile(scratch, 90, 100),
            percentile(scratch, 99, 100),
            scratch[scratch.len - 1],
            any_miss,
        },
    );
}

fn reportHistogram(b: Bench, out: *std.Io.Writer) !void {
    var counts = [_]usize{0} ** (bucket_edges.len + 1);
    for (b.samples) |s| {
        var bucket: usize = bucket_edges.len;
        for (bucket_edges, 0..) |edge, i| {
            if (s.dur_ns < edge) {
                bucket = i;
                break;
            }
        }
        counts[bucket] += 1;
    }
    try out.print("  {s:12}", .{b.name});
    for (counts) |c| try out.print("  {d:>7}", .{c});
    try out.print("\n", .{});
}

fn dumpCsv(path: []const u8, benches: []const Bench, io: std.Io) !void {
    var dir = std.Io.Dir.cwd();
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);

    var buf: [16384]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    defer w.flush() catch {};

    try w.print("timer,run_idx,ts_ns,dur_ns,l1_misses\n", .{});
    for (benches) |b| {
        for (b.samples, 0..) |s, i| {
            try w.print("{s},{d},{d},{d},{d}\n", .{ b.name, i, s.ts_ns, s.dur_ns, s.l1_misses });
        }
    }
}
