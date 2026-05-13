const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const btf = std.os.linux.BPF.btf;
const assert = std.debug.assert;

const Clock = @This();

seconds: u64 = undefined,
nanos: u64 = undefined,
ticks: u64 = undefined,

mul: u64 = undefined,
shr: u6 = undefined,

/// Verifies whether the current system meets all preconditions to use this clock.
///
/// Currently only checks for TSC invariance.
pub fn verify() bool {
    var max_ext: u32 = undefined;
    var ext_b: u32 = undefined;
    var ext_c: u32 = undefined;
    var ext_d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (max_ext),
          [b] "={ebx}" (ext_b),
          [c] "={ecx}" (ext_c),
          [d] "={edx}" (ext_d),
        : [in_a] "{eax}" (@as(u32, 0x80000000)),
          [in_c] "{ecx}" (@as(u32, 0)),
    );
    _ = .{ ext_b, ext_c, ext_d };
    if (max_ext < 0x80000007) return false;

    var apm_a: u32 = undefined;
    var apm_b: u32 = undefined;
    var apm_c: u32 = undefined;
    var apm_d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (apm_a),
          [b] "={ebx}" (apm_b),
          [c] "={ecx}" (apm_c),
          [d] "={edx}" (apm_d),
        : [in_a] "{eax}" (@as(u32, 0x80000007)),
          [in_c] "{ecx}" (@as(u32, 0)),
    );
    _ = .{ apm_a, apm_b, apm_c };
    if ((apm_d & (1 << 8)) == 0) return false;

    return true;
}

// MARK: CALIBRATION

const SCALE: u6 = 23;
const CALIBRATION_WINDOW_NS: u64 = 100_000;
const VALIDATION_TOLERANCE_NS: u64 = 50_000;

pub fn init() @This() {
    return if (bypass) |b| b.read() else calibrate();
}

/// Self-calibrate the period against `CLOCK_REALTIME`.
pub fn calibrate() @This() {
    const SAMPLES: usize = 101;
    var raw: [SAMPLES * 2]u64 = undefined;
    for (&raw) |*slot| {
        const wall_start = realtime();
        const cyc_start = instant();
        while (realtime() < wall_start + CALIBRATION_WINDOW_NS) std.atomic.spinLoopHint();
        const wall_end = realtime();
        const cyc_end = instant();
        slot.* = ((wall_end - wall_start) << SCALE) / (cyc_end -% cyc_start);
    }
    var valid = raw[SAMPLES..];
    std.mem.sort(u64, valid, {}, std.sort.asc(u64));
    const lo = 2 * SAMPLES / 5;
    const hi = lo + SAMPLES / 5;
    var sum: u64 = 0;
    for (valid[lo..hi]) |v| sum += v;

    const anchor = sandwich();
    return .{
        .seconds = anchor.sec,
        .nanos = anchor.nsec << SCALE,
        .ticks = anchor.ticks,
        .mul = sum / (hi - lo),
        .shr = SCALE,
    };
}

pub fn refresh(self: *@This()) void {
    if (bypass) |_| self.refreshBypass() else self.refreshSystem();
}

pub inline fn refreshBypass(self: *@This()) void {
    if (bypass) |b| self.* = b.read() else unreachable;
}

pub inline fn refreshSystem(self: *@This()) void {
    const anchor = sandwich();
    self.seconds = anchor.sec;
    self.nanos = anchor.nsec << self.shr;
    self.ticks = anchor.ticks;
}

/// Sandwich `clock_gettime` between two `rdtscp` reads so that
/// `base_ticks`'s midpoint roughly matches the wall sample.
/// Retries on cross-core migration.
inline fn sandwich() struct { sec: u64, nsec: u64, ticks: u64 } {
    while (true) {
        const before = checkpoint();
        var ts: linux.timespec = undefined;
        assert(linux.clock_gettime(linux.CLOCK.REALTIME, &ts) == 0);
        const after = checkpoint();

        if (before.cpuid != after.cpuid) continue;

        return .{
            .sec = @intCast(ts.sec),
            .nsec = @intCast(ts.nsec),
            .ticks = before.ticks +% (after.ticks -% before.ticks) / 2,
        };
    }
}

// MARK: MEASUREMENT

/// Nanoseconds since the Unix epoch, extrapolated from the stored anchor.
///
/// Drifts between refreshes. If `setup` successfully installed the vDSO
/// bypass, refreshes will include NTP rate corrections.
pub fn now(self: *const @This()) u64 {
    const delta = instant() -% self.ticks;
    return self.seconds *% std.time.ns_per_s + ((self.nanos +% delta *% self.mul) >> self.shr);
}

pub inline fn instant() u64 {
    return checkpoint().ticks;
}

pub inline fn checkpoint() struct { ticks: u64, cpuid: u32 } {
    return switch (builtin.cpu.arch) {
        .x86_64 => blk: {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            var aux: u32 = undefined;
            asm volatile ("rdtscp"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
                  [aux] "={ecx}" (aux),
            );
            break :blk .{ .ticks = (@as(u64, hi) << 32) | @as(u64, lo), .cpuid = aux };
        },
        .aarch64 => switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => blk: {
                break :blk .{ .ticks = 0, .cpuid = 0 }; // TODO
            },
            .linux => blk: {
                break :blk .{ .ticks = 0, .cpuid = 0 }; // TODO
            },
            else => @compileError("The target operating system is not supported by meazure."),
        },
        else => @compileError("The target architecture is not supported by meazure."),
    };
}

pub inline fn realtime() u64 {
    var ts: linux.timespec = undefined;
    assert(linux.clock_gettime(linux.CLOCK.REALTIME, &ts) == 0);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Elapsed nanoseconds since the given instant.
///
/// Clamps to zero on TSC wraparound or when core migration drift exceeds elapsed duration.
pub inline fn elapsed(self: *const @This(), since: u64) u64 {
    const until = instant();
    if (until >= since) return self.timespan(until - since) else {
        @branchHint(.cold);
        return 0;
    }
}

/// Turns a tickspan into a timespan.
pub inline fn timespan(self: *const @This(), tickspan: u64) u64 {
    return (tickspan *% self.mul) >> self.shr;
}

// MARK: vDSO BYPASS

var bypass: ?Bypass = null;

pub fn setup(io: std.Io, allocator: std.mem.Allocator) !void {
    bypass = try Bypass.init(io, allocator);
    const our = bypass.?.read().now();
    const ref = realtime();
    const diff = if (ref > our) ref - our else our - ref;
    if (diff <= VALIDATION_TOLERANCE_NS) return;

    disable();
    return error.BTFUnavailable;
}

pub fn disable() void {
    bypass = null;
}

pub const Bypass = struct {
    seq: *const u32 = undefined,
    cycle_last: *const volatile u64 = undefined,
    mult: *const volatile u32 = undefined,
    shift: *const volatile u32 = undefined,
    sec: *const volatile u64 = undefined,
    nsec: *const volatile u64 = undefined,

    pub fn read(self: @This()) Clock {
        while (true) {
            const begin = @atomicLoad(u32, self.seq, .acquire);
            if (begin & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }

            const shift: u6 = @intCast(self.shift.*);
            const result: Clock = .{
                .seconds = self.sec.*,
                .nanos = self.nsec.*,
                .ticks = self.cycle_last.*,
                .mul = self.mult.*,
                .shr = shift,
            };
            if (@atomicLoad(u32, self.seq, .acquire) == begin) return result;
        }
    }

    const BTF_PATH = "/sys/kernel/btf/vmlinux";
    const VVAR_PAGES_BEFORE_VDSO: usize = 4;
    const VDSO_DATA_OFFSET_IN_VVAR: usize = 128;
    const CLOCK_REALTIME_INDEX: u32 = 0;
    const AT_SYSINFO_EHDR: usize = 33;

    pub fn init(io: std.Io, alloc: std.mem.Allocator) !@This() {
        const vdso_base = linux.getauxval(AT_SYSINFO_EHDR);
        if (vdso_base == 0) return error.BTFUnavailable;
        const page_sz: usize = std.heap.pageSize();
        const vvar_base = vdso_base - VVAR_PAGES_BEFORE_VDSO * page_sz;
        const vdso_data_base = vvar_base + VDSO_DATA_OFFSET_IN_VVAR;

        const file = try std.Io.Dir.openFileAbsolute(io, BTF_PATH, .{});
        defer file.close(io);
        const size: usize = (try file.stat(io)).size;
        var mm = std.Io.File.MemoryMap.create(io, file, .{
            .len = size,
            .protection = .{ .read = true, .write = false },
            .populate = false,
        }) catch return error.BTFUnavailable;
        defer mm.destroy(io);
        const blob = mm.memory[0..size];
        if (blob.len < @sizeOf(btf.Header)) return error.BTFUnavailable;

        const hdr = @as(*const btf.Header, @ptrCast(@alignCast(blob.ptr))).*;
        if (hdr.magic != btf.magic) return error.BTFUnavailable;
        if (hdr.version != btf.version) return error.BTFUnavailable;

        const ts = hdr.hdr_len + hdr.type_off;
        const te = ts + hdr.type_len;
        const ss = hdr.hdr_len + hdr.str_off;
        const se = ss + hdr.str_len;
        if (te > blob.len or se > blob.len) return error.BTFUnavailable;
        const types = blob[ts..te];
        const strings = blob[ss..se];

        var index: std.ArrayListUnmanaged(u32) = .empty;
        defer index.deinit(alloc);
        {
            var off: usize = 0;
            while (off + @sizeOf(btf.Type) <= types.len) {
                const t = @as(*align(1) const btf.Type, @ptrCast(types.ptr + off)).*;
                const rec = recordSize(t);
                if (off + rec > types.len) return error.BTFUnavailable;
                index.append(alloc, @intCast(off)) catch return error.BTFUnavailable;
                off += rec;
            }
        }

        const vd_names = [_][]const u8{ "seq", "cycle_last", "mult", "shift", "basetime" };
        var vd_off: [vd_names.len]u32 = undefined;
        _ = lookupFields(alloc, types, strings, index.items, "vdso_data", &vd_names, &vd_off) catch return error.BTFUnavailable;

        const ts_names = [_][]const u8{ "sec", "nsec" };
        var ts_off: [ts_names.len]u32 = undefined;
        const ts_size = lookupFields(alloc, types, strings, index.items, "vdso_timestamp", &ts_names, &ts_off) catch return error.BTFUnavailable;

        const realtime_base = vd_off[4] + CLOCK_REALTIME_INDEX * ts_size;

        return .{
            .seq = @ptrFromInt(vdso_data_base + vd_off[0]),
            .cycle_last = @ptrFromInt(vdso_data_base + vd_off[1]),
            .mult = @ptrFromInt(vdso_data_base + vd_off[2]),
            .shift = @ptrFromInt(vdso_data_base + vd_off[3]),
            .sec = @ptrFromInt(vdso_data_base + realtime_base + ts_off[0]),
            .nsec = @ptrFromInt(vdso_data_base + realtime_base + ts_off[1]),
        };
    }

    fn recordSize(t: btf.Type) usize {
        const base = @sizeOf(btf.Type);
        const v: usize = t.info.vlen;
        return base + switch (t.info.kind) {
            .int => @sizeOf(btf.IntInfo),
            .@"var" => @sizeOf(btf.Var),
            .decl_tag => @sizeOf(btf.DeclTag),
            .array => @sizeOf(btf.Array),
            .@"struct", .@"union" => v * @sizeOf(btf.Member),
            .@"enum" => v * @sizeOf(btf.Enum),
            .enum64 => v * @sizeOf(btf.Enum64),
            .func_proto => v * @sizeOf(btf.Param),
            .datasec => v * @sizeOf(btf.VarSecInfo),
            else => @as(usize, 0),
        };
    }

    fn nameAt(strings: []const u8, off: u32) []const u8 {
        if (off >= strings.len) return "";
        const tail = strings[off..];
        const end = std.mem.indexOfScalar(u8, tail, 0) orelse tail.len;
        return tail[0..end];
    }

    fn typeOffsetForId(index: []const u32, target: u32) ?usize {
        if (target == 0 or target > index.len) return null;
        return index[target - 1];
    }

    fn lookupFields(
        allocator: std.mem.Allocator,
        types: []const u8,
        strings: []const u8,
        index: []const u32,
        struct_name: []const u8,
        wanted: []const []const u8,
        offsets_out: []u32,
    ) !u32 {
        assert(wanted.len == offsets_out.len);

        const struct_off = blk: {
            var off: usize = 0;
            while (off + @sizeOf(btf.Type) <= types.len) {
                const t = @as(*align(1) const btf.Type, @ptrCast(types.ptr + off)).*;
                if (t.info.kind == .@"struct" and std.mem.eql(u8, nameAt(strings, t.name_off), struct_name)) {
                    break :blk off;
                }
                off += recordSize(t);
            }
            return error.StructNotFound;
        };
        const struct_t = @as(*align(1) const btf.Type, @ptrCast(types.ptr + struct_off)).*;

        const found = try allocator.alloc(bool, wanted.len);
        defer allocator.free(found);
        @memset(found, false);

        const Frame = struct { type_off: usize, base_bit_offset: u32 };
        var stack: std.ArrayListUnmanaged(Frame) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, .{ .type_off = struct_off, .base_bit_offset = 0 });

        while (stack.pop()) |frame| {
            const t = @as(*align(1) const btf.Type, @ptrCast(types.ptr + frame.type_off)).*;
            if (t.info.kind != .@"struct" and t.info.kind != .@"union") continue;
            var i: u16 = 0;
            while (i < t.info.vlen) : (i += 1) {
                const mp = types.ptr + frame.type_off + @sizeOf(btf.Type) + @as(usize, i) * @sizeOf(btf.Member);
                const m = @as(*align(1) const btf.Member, @ptrCast(mp)).*;
                const member_bit_off: u32 = if (t.info.kind_flag) m.offset.bit else @as(u32, @bitCast(m.offset));
                const abs_bit_off = frame.base_bit_offset + member_bit_off;
                const member_name = nameAt(strings, m.name_off);
                if (member_name.len == 0) {
                    if (typeOffsetForId(index, m.typ)) |sub_off| {
                        try stack.append(allocator, .{ .type_off = sub_off, .base_bit_offset = abs_bit_off });
                    }
                } else {
                    for (wanted, 0..) |w, j| {
                        if (!found[j] and std.mem.eql(u8, w, member_name)) {
                            offsets_out[j] = abs_bit_off / 8;
                            found[j] = true;
                            break;
                        }
                    }
                }
            }
        }

        for (found) |f| if (!f) return error.FieldNotFound;
        return struct_t.size_type.size;
    }
};
