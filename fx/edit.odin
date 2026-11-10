// Tools for edits cut to music: beats, camera shake and punch-ins, flashes,
// letterboxing, transitions between overlapping scenes, speed ramps and
// title slams.
package fx

import "core:math"
import sk "../sk"

// ---------------------------------------------------------------- beats

// Onset times moved to video time (the file plays from `from` at video time
// `at`), keeping those inside [from, to) of the file that are at least as
// strong and as loud as asked. Allocated with context.allocator.
times :: proc(hits: []Onset, from: f32 = 0, at: f32 = 0, to: f32 = max(f32), strength: f32 = 0, level: f32 = 0) -> []f32 {
	out: [dynamic]f32
	for h in hits {
		if h.t < from || h.t >= to || h.strength < strength || h.level < level do continue
		append(&out, h.t - from + at)
	}
	return out[:]
}

// The last beat at or before t: its index (-1 before the first) and the
// time since it (since t = 0 before the first).
beat :: proc(beats: []f32, t: f32) -> (i: int, since: f32) {
	lo, hi := 0, len(beats)
	for lo < hi {
		mid := (lo + hi) / 2
		if beats[mid] <= t do lo = mid + 1
		else do hi = mid
	}
	i = lo - 1
	return i, i >= 0 ? t - beats[i] : t
}

// 1 on each beat, falling to 0 over dur: drives flashes, punches, shakes.
pulse :: proc(beats: []f32, t: f32, dur: f32 = 0.25, e: Ease = ease_out) -> f32 {
	i, since := beat(beats, t)
	if i < 0 do return 0
	return 1 - e(prog(since, 0, dur))
}

// 1 at t0, falling to 0 over dur (0 before t0).
hit :: proc(t, t0, dur: f32, e: Ease = ease_out) -> f32 {
	if t < t0 do return 0
	return 1 - e(prog(t, t0, t0 + dur))
}

// ---------------------------------------------------------------- camera

// Smooth value noise in [-1, 1].
noise1 :: proc(x: f32, seed: f32 = 0) -> f32 {
	i := math.floor(x)
	f := x - i
	a := hash01(u32(seed * 977 + 13), int(i)) * 2 - 1
	b := hash01(u32(seed * 977 + 13), int(i) + 1) * 2 - 1
	return lerp(a, b, f * f * (3 - 2 * f))
}

// Shake offset in px: amount at freq wobbles per second.
shake :: proc(t: f32, amount: f32, freq: f32 = 14, seed: f32 = 0) -> Vec2 {
	if amount == 0 do return {}
	return {noise1(t * freq, seed) * amount, noise1(t * freq, seed + 17) * amount}
}

// A whole-stage camera: zoom around the center, moved and rotated.
camera :: proc(zoom: f32 = 1, offset := Vec2{}, rot: f32 = 0) -> Xf {
	return {x = offset.x, y = offset.y, s = zoom, rot = rot, origin = center(stage())}
}

// ---------------------------------------------------------------- frames

// The stage covered in c at opacity a.
flash :: proc(a: f32, c: Color = 0xffffffff) {
	if a > 0.003 do rect(stage(), alpha(c, a))
}

// Cinema bars cropping the stage to ratio, slid in by amount (0..1).
letterbox :: proc(amount: f32 = 1, ratio: f32 = 2.39, c: Color = 0xff000000) {
	bar := max((S.h - S.w / ratio) / 2, 0) * clamp01(amount)
	if bar < 0.5 do return
	rect({0, 0, S.w, bar}, c)
	rect({0, S.h - bar, S.w, bar}, c)
}

// ---------------------------------------------------------------- transitions

Transition :: enum {
	Cut,
	Fade, // the incoming scene fades in over the outgoing one
	Whip_Left, // both slide left, side by side, motion-blurred
	Whip_Right,
	Whip_Up,
	Whip_Down,
	Zoom, // rush into the outgoing scene, out of the incoming one (radial blur)
	Spin, // a quarter turn out, a quarter turn in, blurred
	Glitch, // slices and color split around the cut
	Blur, // out of focus, cut, back into focus
}

// The Xf for a scene that enters with one transition and leaves with
// another, each taking dur at its edge. A transition happens across two
// overlapping scenes: start the next scene dur before this one ends and give
// both the same kind (this one's leave, the next one's enter).
transition :: proc(s: Shot, enter, leave: Transition, dur: f32 = 0.4) -> Xf {
	if enter != .Cut && s.lt < dur do return trans_xf(enter, s.lt / dur, true, dur)
	if leave != .Cut && s.lt > s.dur - dur do return trans_xf(leave, (s.lt - (s.dur - dur)) / dur, false, dur)
	return {}
}

// The Xf of one side of a transition at p (0..1 across the overlap).
trans_xf :: proc(k: Transition, p: f32, incoming: bool, dur: f32) -> Xf {
	W, H := S.w, S.h
	c := center(stage())
	fps := f32(S.video != nil && S.video.fps > 0 ? S.video.fps : 60)
	// how fast an eased value moves at p, per frame (for motion blur)
	speed :: proc(e: Ease, p, dur, fps: f32) -> f32 {
		h :: 0.01
		return (e(min(p + h, 1)) - e(max(p - h, 0))) / (min(p + h, 1) - max(p - h, 0)) / dur / fps
	}
	switch k {
	case .Cut:
		return {}
	case .Fade:
		return incoming ? {o = p} : {}
	case .Whip_Left, .Whip_Right, .Whip_Up, .Whip_Down:
		e := ease_in_out(p)
		v := speed(ease_in_out, p, dur, fps)
		horiz := k == .Whip_Left || k == .Whip_Right
		dir: f32 = k == .Whip_Left || k == .Whip_Up ? -1 : 1
		size := horiz ? W : H
		off := incoming ? -dir * size * (1 - e) : dir * size * e
		blur := min(v * size * 0.35, 140)
		return horiz ? {x = off, mblur = {blur, 0}} : {y = off, mblur = {0, blur}}
	case .Zoom:
		// out: rush in over the first half; in: settle from zoomed over the second
		if !incoming {
			if p >= 0.5 do return {o = 0}
			q := p * 2
			return {s = 1 + 1.6 * ease_in(q), origin = c, post = zoom_blur(c, 0.22 * ease_in(q))}
		}
		if p < 0.5 do return {o = 0}
		q := (p - 0.5) * 2
		return {s = 1 + 0.9 * (1 - ease_out(q)), origin = c, post = zoom_blur(c, 0.18 * (1 - ease_out(q)))}
	case .Spin:
		if !incoming {
			if p >= 0.5 do return {o = 0}
			q := ease_in(p * 2)
			return {rot = 90 * q, s = 1 + 0.4 * q, origin = c, blur = 24 * q}
		}
		if p < 0.5 do return {o = 0}
		q := 1 - ease_out((p - 0.5) * 2)
		return {rot = -90 * q, s = 1 + 0.4 * q, origin = c, blur = 24 * q}
	case .Glitch:
		a := 1 - abs(p - 0.5) * 2
		if incoming != (p >= 0.5) do return {o = 0}
		return {post = glitch(a), x = (hash01(5, int(S.t * 24)) - 0.5) * 40 * a}
	case .Blur:
		a := 1 - abs(p - 0.5) * 2
		if incoming != (p >= 0.5) do return {o = 0}
		return {blur = 40 * ease_in2(a), s = 1 + 0.06 * a, origin = c, bright = 1 + 0.4 * a}
	}
	return {}
}

// ---------------------------------------------------------------- time

// Where a clip is after lt seconds when its playback speed follows keys
// (t = clip time, v = speed; linear between keys, held outside them): the
// source time for speed ramps and freeze frames.
ramp :: proc(lt: f32, ks: []Key) -> f32 {
	if len(ks) == 0 do return lt
	if lt <= ks[0].t do return lt * ks[0].v
	acc := ks[0].t * ks[0].v
	for i in 1 ..< len(ks) {
		a, b := ks[i - 1], ks[i]
		if lt <= b.t {
			v := lerp(a.v, b.v, prog(lt, a.t, b.t))
			return acc + (lt - a.t) * (a.v + v) / 2
		}
		acc += (b.t - a.t) * (a.v + b.v) / 2
	}
	last := ks[len(ks) - 1]
	return acc + (lt - last.t) * last.v
}

// ---------------------------------------------------------------- titles

// Text slammed in at t0: drops from a bigger, blurred copy onto its place
// in a few frames. anchor as in label.
slam :: proc(s: string, p: Vec2, f: Font, c: Color, t, t0: f32, dur: f32 = 0.16, anchor := Vec2{0.5, 0.5}) -> Rect {
	if t < t0 do return {}
	k := ease_out(prog(t, t0, t0 + dur))
	r: Rect
	if group({s = 1 + 0.5 * (1 - k), origin = p, o = min(k * 3, 1), blur = 12 * (1 - k)}) {
		r = label(s, p, f, c, anchor)
	}
	return r
}

// Text drawn as an outline only.
outline :: proc(s: string, p: Vec2, f: Font, c: Color, width: f32 = 2, anchor := Vec2{0.5, 0.5}) -> Rect {
	t := shape(s, f)
	m := metrics(t)
	x, y := p.x - m.width * anchor.x, p.y - m.height * anchor.y
	pt := stroke(c, width)
	sk.text_draw(S.cv, t, x, y, &pt)
	return {x, y, m.width, m.height}
}
