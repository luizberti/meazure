//! Requires either `perf_event_paranoid <= 1` or `cap_perfmon`
//!
//! ```bash
//! sudo setcap cap_perfmon=ep ./your-program
//! ```

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const Error = error{
    PerfOpenFailed,
    PerfMmapFailed,
    PerfRdpmcUnavailable,
};

pub const L1dMissCounter = struct {
    fd: i32,
    page_slice: []align(std.heap.page_size_min) u8,
    rdpmc_index: u32,

    pub fn init() Error!L1dMissCounter {
        // PERF_COUNT_HW_CACHE config layout:
        //   bits 0-7   cache id
        //   bits 8-15  op id
        //   bits 16-23 result id
        const cache_id: u64 = @intFromEnum(linux.PERF.COUNT.HW.CACHE.L1D);
        const op_id: u64 = @intFromEnum(linux.PERF.COUNT.HW.CACHE.OP.READ);
        const res_id: u64 = @intFromEnum(linux.PERF.COUNT.HW.CACHE.RESULT.MISS);
        const config: u64 = cache_id | (op_id << 8) | (res_id << 16);

        var attr: linux.perf_event_attr = .{
            .type = .HW_CACHE,
            .config = config,
            .flags = .{
                .pinned = true,
                .exclude_kernel = true,
                .exclude_hv = true,
                .exclude_idle = true,
            },
        };

        const fd_signed = std.posix.perf_event_open(&attr, 0, -1, -1, 0) catch return error.PerfOpenFailed;
        const fd: i32 = @intCast(fd_signed);
        errdefer _ = linux.close(fd);

        const page_size = std.heap.pageSize();
        const slice = std.posix.mmap(
            null,
            page_size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.PerfMmapFailed;
        errdefer std.posix.munmap(slice);

        const page: *const linux.perf_event_mmap_page = @ptrCast(@alignCast(slice.ptr));
        if (!page.capabilities.user_rdpmc or page.index == 0) {
            return error.PerfRdpmcUnavailable;
        }

        return .{
            .fd = fd,
            .page_slice = slice,
            .rdpmc_index = page.index - 1,
        };
    }

    pub fn deinit(self: *L1dMissCounter) void {
        std.posix.munmap(self.page_slice);
        _ = linux.close(self.fd);
        self.* = undefined;
    }

    pub inline fn read(self: *const L1dMissCounter) u64 {
        const idx = self.rdpmc_index;
        return switch (builtin.cpu.arch) {
            .x86_64 => blk: {
                var lo: u32 = undefined;
                var hi: u32 = undefined;
                asm volatile ("rdpmc"
                    : [lo] "={eax}" (lo),
                      [hi] "={edx}" (hi),
                    : [idx] "{ecx}" (idx),
                );
                break :blk (@as(u64, hi) << 32) | @as(u64, lo);
            },
            else => unreachable,
        };
    }
};
