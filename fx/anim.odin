// Time helpers. Nothing here keeps time of its own: every value is computed
// from t, so any frame can be drawn in any order.
package fx

import "core:math"
import "core:unicode/utf8"

clamp01 :: proc(x: f32) -> f32 {return math.clamp(x, 0, 1)}
lerp :: proc(a, b, p: f32) -> f32 {return a + (b - a) * p}
lerp2 :: proc(a, b: Vec2, p: f32) -> Vec2 {return a + (b - a) * p}
// Linear progress of t through [a, b], clamped to 0..1.
prog :: proc(t, a, b: f32) -> f32 {return b == a ? (t >= b ? 1 : 0) : clamp01((t - a) / (b - a))}

Ease :: #type proc(p: f32) -> f32

ease_linear :: proc(p: f32) -> f32 {return p}
ease_out :: proc(p: f32) -> f32 {q := 1 - p; return 1 - q * q * q}
ease_out5 :: proc(p: f32) -> f32 {q := 1 - p; return 1 - q * q * q * q * q}
ease_in :: proc(p: f32) -> f32 {return p * p * p}
ease_in2 :: proc(p: f32) -> f32 {return p * p}
ease_in_out :: proc(p: f32) -> f32 {
	if p < 0.5 do return 4 * p * p * p
	q := -2 * p + 2
	return 1 - q * q * q / 2
}
ease_expo :: proc(p: f32) -> f32 {return p >= 1 ? 1 : 1 - math.pow(2, -10 * p)}
ease_back :: proc(p: f32) -> f32 {
	c :: 1.5
	q := p - 1
	return 1 + (c + 1) * q * q * q + c * q * q
}
// Damped spring settling at 1; freq in Hz-ish, damping 0..1.
spring :: proc(p: f32, freq: f32 = 2.2, damping: f32 = 0.45) -> f32 {
	if p <= 0 do return 0
	return 1 - math.exp(-damping * 10 * p) * math.cos(freq * math.TAU * p)
}

// Eased progress of t through [a, b].
ep :: proc(t, a, b: f32, e: Ease = ease_out) -> f32 {return e(prog(t, a, b))}
// 0 → 1 over [a, a+fi], 1 → 0 over [b-fo, b]: a visibility window.
win :: proc(t, a, b: f32, fi: f32 = 0.4, fo: f32 = 0.4) -> f32 {
	return min(ep(t, a, a + fi), 1 - ep(t, b - fo, b, ease_in2))
}
// Eased progress for the i-th of a staggered set starting at a, step apart.
stagger :: proc(t: f32, i: int, a, step, dur: f32, e: Ease = ease_out) -> f32 {
	s := a + f32(i) * step
	return ep(t, s, s + dur, e)
}
// Smooth pseudo-random wobble in [-1, 1] for camera drift and jitter.
wob :: proc(t: f32, seed: f32 = 0) -> f32 {
	return math.sin(t * 1.3 + seed * 12.9898) * 0.6 + math.sin(t * 2.7 + seed * 78.233) * 0.4
}
// Cubic bezier point for p in [0, 1].
bez :: proc(p, a, b, c, d: f32) -> f32 {
	q := 1 - p
	return q * q * q * a + 3 * q * q * p * b + 3 * q * p * p * c + p * p * p * d
}

// Deterministic random numbers (mulberry32).
Rng :: struct {
	s: u32,
}
rng :: proc(seed: u32) -> Rng {return {seed}}
rand :: proc(r: ^Rng) -> f32 {
	r.s += 0x6d2b79f5
	t := r.s
	t = (t ~ (t >> 15)) * (1 | t)
	t = (t + (t ~ (t >> 7)) * (61 | t)) ~ t
	return f32(t ~ (t >> 14)) / 4294967296
}
// Stable random number for (seed, i), no state.
hash01 :: proc(seed: u32, i: int) -> f32 {
	r := rng(seed * 2654435761 + u32(i) * 40503)
	return rand(&r)
}

// The prefix of text typed out over [t0, t1], cut at a whole character.
typed :: proc(text: string, t, t0, t1: f32) -> string {
	n := utf8.rune_count_in_string(text)
	k := int(math.round(f32(n) * prog(t, t0, t1)))
	if k >= n do return text
	i := 0
	for _, off in text {
		if i == k do return text[:off]
		i += 1
	}
	return text
}
// Number counting from a to b over [t0, t1].
count :: proc(t, t0, t1, a, b: f32, e: Ease = ease_out) -> f32 {return lerp(a, b, ep(t, t0, t1, e))}

// ---------------------------------------------------------------- keyframes

Key :: struct {
	t: f32,
	v: f32,
}
// Value at t between keyframes, eased per segment; holds outside the range.
keys :: proc(ks: []Key, t: f32, e: Ease = ease_in_out) -> f32 {
	if len(ks) == 0 do return 0
	if t <= ks[0].t do return ks[0].v
	for i in 1 ..< len(ks) {
		if t < ks[i].t do return lerp(ks[i - 1].v, ks[i].v, e(prog(t, ks[i - 1].t, ks[i].t)))
	}
	return ks[len(ks) - 1].v
}

Key2 :: struct {
	t: f32,
	p: Vec2,
}
keys2 :: proc(ks: []Key2, t: f32, e: Ease = ease_in_out) -> Vec2 {
	if len(ks) == 0 do return {}
	if t <= ks[0].t do return ks[0].p
	for i in 1 ..< len(ks) {
		if t < ks[i].t do return lerp2(ks[i - 1].p, ks[i].p, e(prog(t, ks[i - 1].t, ks[i].t)))
	}
	return ks[len(ks) - 1].p
}
