package obench

import "base:intrinsics"
import "core:math"
import "core:time"

when ODIN_OS != .Linux {
	@(private = "file", require_results)
	_monotonic_tick :: #force_inline proc "contextless" () -> time.Tick {
		return time.tick_now()
	}
}

/*
`true` when `intrinsics.read_cycle_counter` reads a CPU cycle counter (the x86 time-stamp
counter, which ticks at the nominal reference frequency).

On other architectures the intrinsic reads a fixed-frequency system timer instead (24 MHz
`CNTVCT_EL0` on Apple Silicon, for example), which carries no information beyond
wall-clock time, so obench does not report cycles there.
*/
CYCLE_COUNTER_SUPPORTED :: ODIN_ARCH == .amd64 || ODIN_ARCH == .i386

// Monotonic wall-clock and CPU cycle snapshot.
Timestamp :: struct {
	tick:   time.Tick,
	cycles: u64, // Always 0 when `CYCLE_COUNTER_SUPPORTED` is false.
}

// Calibrated properties of the benchmark clock.
//
// `overhead_ns` is authoritative for clock-overhead subtraction. `overhead_fs` stores the
// calibrated per-window overhead in femtoseconds alongside `overhead_ns` for sub-nanosecond
// batch scaling, and is only used when it agrees with `overhead_ns`. Setting or mutating
// `overhead_fs` alone without a matching `overhead_ns` has no effect; if a caller modifies
// `overhead_ns` directly after calibration, the runner detects the divergence and derives the
// integer batch overhead from `overhead_ns`.
Clock_Calibration :: struct {
	overhead_ns:       f64, // Cost of one timed window (two back-to-back `clock_now` calls).
	overhead_fs:       i64, // Cost of one timed window in femtoseconds (1e-6 ns).
	overhead_cycles:   f64, // Same as `overhead_ns`, in cycles. 0 without a cycle counter.
	resolution_ns:     f64, // Smallest observed non-zero tick difference.
	has_cycle_counter: bool, // Mirrors `CYCLE_COUNTER_SUPPORTED`.
}

// Captures the current monotonic timestamp and, when supported, the CPU cycle counter.
@(require_results)
clock_now :: #force_inline proc "contextless" () -> Timestamp {
	when CYCLE_COUNTER_SUPPORTED {
		return Timestamp{tick = _monotonic_tick(), cycles = u64(intrinsics.read_cycle_counter())}
	} else {
		return Timestamp{tick = _monotonic_tick()}
	}
}

// Computes elapsed nanoseconds and CPU cycles between two timestamps.
@(require_results)
clock_elapsed :: #force_inline proc "contextless" (
	start, end: Timestamp,
) -> (
	ns: i64,
	cycles: u64,
) {
	ns_diff := i64(time.tick_diff(start.tick, end.tick))
	if ns_diff < 0 {
		ns_diff = 0
	}
	cycle_diff: u64 = 0
	if end.cycles >= start.cycles {
		cycle_diff = end.cycles - start.cycles
	}
	return ns_diff, cycle_diff
}

/*
Measures the cost of a timed window (back-to-back `clock_now()` calls) and the timer
resolution. obench subtracts `overhead_ns` once per timed window from every sample.

The overhead is the mean window over a block of windows, and the lowest mean of several
blocks. A clock that ticks more coarsely than one window (24 MHz on Apple Silicon) reads
most single windows as 0, but the mean over many windows still converges to the true cost.
Taking the lowest block drops blocks hit by an interrupt.
*/
@(require_results)
clock_calibrate :: proc "contextless" () -> Clock_Calibration {
	BLOCKS :: 16
	WINDOWS_PER_BLOCK :: 256
	best_sum_ns: i128 = max(i128)
	best_cycles := max(f64)

	for _ in 0 ..< BLOCKS {
		sum_ns: i128 = 0
		sum_cycles: u64 = 0
		for _ in 0 ..< WINDOWS_PER_BLOCK {
			t0 := clock_now()
			clobber_memory()
			t1 := clock_now()
			ns, cyc := clock_elapsed(t0, t1)
			sum_ns += i128(ns)
			sum_cycles += cyc
		}
		if sum_ns >= 0 {
			best_sum_ns = min(best_sum_ns, sum_ns)
			best_cycles = min(best_cycles, f64(sum_cycles) / WINDOWS_PER_BLOCK)
		}
	}
	if best_sum_ns == max(i128) {
		best_sum_ns = 0
		best_cycles = 0
	}
	best_ns := f64(best_sum_ns) / WINDOWS_PER_BLOCK

	// Resolution: the smallest non-zero step of the monotonic clock.
	min_step: i64 = max(i64)
	for _ in 0 ..< 32 {
		start := _monotonic_tick()
		for spin := 0; spin < 1_000_000; spin += 1 {
			now := _monotonic_tick()
			diff := i64(time.tick_diff(start, now))
			if diff > 0 {
				if diff < min_step {
					min_step = diff
				}
				break
			}
		}
	}
	if min_step == max(i64) {
		min_step = 0
	}

	return Clock_Calibration {
		overhead_ns = best_ns,
		overhead_fs = i64(
			min(
				(best_sum_ns * 1_000_000 + WINDOWS_PER_BLOCK / 2) / WINDOWS_PER_BLOCK,
				i128(max(i64)),
			),
		),
		overhead_cycles = best_cycles,
		resolution_ns = f64(min_step),
		has_cycle_counter = CYCLE_COUNTER_SUPPORTED,
	}
}

@(private = "file")
// Smallest `f64` nanosecond overhead where `math.round(ov_ns * 1e6) >= 2^63` (overflows `i64` fs).
_OVERHEAD_FS_LIMIT_NS :: 9.223372036854775e12

@(private = "file")
// Exact `2^63` as `f64` (`max(i64) + 1`). Any batch overhead `>= _TWO_POW_63` clamps every
// `i64` duration to `0`.
_TWO_POW_63 :: 9223372036854775808.0

// Resolves per-window clock overhead into a non-negative `f64` nanosecond value and an
// integer femtosecond value (capped at `max(i64)` fs so `ov_fs * win_cnt + 500_000` never
// overflows `i128` for any `win_cnt <= max(i64)`).
//
// `overhead_ns` is authoritative: negative and `NaN` values clamp to `0`, and `overhead_fs`
// is used only when it agrees with `overhead_ns` within rounding tolerance.
@(private, require_results)
_clock_resolve_overhead :: proc "contextless" (
	clock: Clock_Calibration,
) -> (
	ov_ns: f64,
	ov_fs: i128,
) {
	ov_ns = clock.overhead_ns if clock.overhead_ns > 0 else 0.0
	if ov_ns == 0 {
		return 0.0, 0
	}
	fs_matches_ns :=
		!math.is_inf(ov_ns, 0) &&
		clock.overhead_fs > 0 &&
		abs(f64(clock.overhead_fs) / 1_000_000.0 - ov_ns) <= 5e-7 + 1e-12 * max(ov_ns, 1.0)
	if fs_matches_ns {
		return ov_ns, i128(clock.overhead_fs)
	}
	if ov_ns >= _OVERHEAD_FS_LIMIT_NS {
		return ov_ns, i128(max(i64))
	}
	return ov_ns, i128(i64(math.round(ov_ns * 1_000_000.0)))
}

// Computes the overhead-adjusted integer batch duration (in nanoseconds) for `raw_ns` across
// `windows` timed windows, given `(ov_ns, ov_fs)` from `_clock_resolve_overhead`.
@(private, require_results)
_clock_adjust_batch_ns :: proc "contextless" (
	raw_ns: i64,
	windows: int,
	ov_ns: f64,
	ov_fs: i128,
) -> u64 {
	if raw_ns <= 0 {
		return 0
	}
	win_cnt := max(windows, 1)
	if ov_ns >= _OVERHEAD_FS_LIMIT_NS {
		// Above `_OVERHEAD_FS_LIMIT_NS` (including `+Inf`), `ov_ns` cannot be represented as
		// `i64` femtoseconds. Scale directly in `f64` to stay continuous with `adj_ns` and
		// clamp any total overhead `>= 2^63` (or `+Inf`) unconditionally to `0`.
		ov_batch_f := ov_ns * f64(win_cnt)
		if !(ov_batch_f < _TWO_POW_63) {
			return 0
		}
		ov_batch_ns := i128(i64(math.round(ov_batch_f)))
		return u64(max(i128(raw_ns) - ov_batch_ns, 0))
	}
	ov_batch_ns := (ov_fs * i128(win_cnt) + 500_000) / 1_000_000
	return u64(max(i128(raw_ns) - ov_batch_ns, 0))
}
