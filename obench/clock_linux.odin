package obench

import "core:sys/posix"
import "core:time"

// Linux `CLOCK_MONOTONIC_RAW` (4), matching `core:time` without NTP slew.
// `posix.Clock` only lists the POSIX-mandated clocks, so cast the Linux clock ID directly.
@(private = "file")
CLOCK_MONOTONIC_RAW :: posix.Clock(4)

// Reads `CLOCK_MONOTONIC_RAW` through libc so the kernel vDSO handles it in userspace
// instead of issuing a raw syscall like `core:time.tick_now()`.
@(private, require_results)
_monotonic_tick :: #force_inline proc "contextless" () -> time.Tick {
	ts: posix.timespec
	_ = posix.clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
	ns := i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
	return time.tick_add(time.Tick{}, time.Duration(ns))
}
