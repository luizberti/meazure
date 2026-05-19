# meazure — low-overhead benchmark timer
This is a Zig implementation of the vDSO bypass technique described in [this
blog post](vdso-bypass) by Henrique Cabral. It has a significantly improved
latency distribution over just taking timestamps from Zig's Io interface,
shaving off tens of nanoseconds from the mean and with a much tighter tail.

Most benchmarks don't need this, but some do: if whatever you're trying to
measure is in the low tens of nanoseconds range you will see an improvement,
and even up to 1µs you will probably measure significantly less noise. There
is no downside to using this timer for other types of measurements aside from
having to manually refresh, so you may use it everywhere if you like.

**This library currently only works on x64 on Linux.** Additionally, this will
not work on older x64 hardware that does not implement TSC invariance, but this
is checked at setup time via `cpuid` flags.

The vDSO bypass technique relies on the kernel exposing type information via
BTF. If the kernel was not compiled with `CONFIG_DEBUG_INFO_BTF=y` this will
fail to setup at runtime, and we will fallback to disciplining the timer
through the vDSO against several samples.

> [!WARNING]
> The BTF parsing code is currently brittle. While it works on MY kernel, it
> might not work on yours. The implementation quality of this library is OK,
> definitely not terrible, but needs some polish and the interface will
> likely break when it's time to add support for ARM64 and other OS.


## Usage
```zig
const std = @import("std");
const Clock = @import("meazure").Clock;

pub fn main(init: std.process.Init) !void {
    std.debug.assert(Clock.verify());
    Clock.setup(init.io, init.gpa) catch {}; // attempts the vDSO bypass

    var clock = Clock.init();

    for (0..1000) |_| {
        const inst = clock.instant();
        std.mem.doNotOptimizeAway(doWork());
        const elapsed = clock.elapsed(inst);

        // refresh the timer periodically in your event loop, preferable while
        // there are no outstanding timers actively measuring. You don't have
        // to do it this frequently, and it is not THAT necessary unless
        // you're using clock.now() for an actual timestamp instead of
        // just measuring durations.
        clock.refresh();
    }
}
```


[vdso-bypass]: https://www.hmpcabral.com/2026/04/26/the-fastest-linux-timestamps/
