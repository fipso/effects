// 02 — Attention. Every word looks at every other word, at once, and then
// again in the next layer.
package fable

import "core:math"
import fx "effects:fx"
import sk "effects:sk"

// "You shall know a word by the company it keeps." — J. R. Firth, 1957
WORDS := [?]string{"the", "meaning", "of", "a", "word", "is", "the", "company", "it", "keeps"}
NW :: len(WORDS)

// How much word i attends to word j: a few strong, deliberate pairs over a
// faint random floor. head picks a different pattern.
attend :: proc(i, j: int, head: int) -> f32 {
	if i == j do return 0
	PAIRS := [?][3]int{{4, 1, 0}, {1, 4, 0}, {8, 4, 0}, {9, 7, 0}, {7, 9, 0}, {0, 1, 0}, {6, 7, 0}, {2, 1, 0}, {5, 4, 0}, {3, 4, 0}, {9, 8, 0}, {5, 7, 0}, {1, 7, 0}, {7, 4, 0}, {8, 7, 1}, {4, 7, 1}, {1, 9, 1}, {9, 4, 1}, {0, 6, 1}, {6, 0, 1}, {5, 1, 1}, {2, 4, 1}, {3, 7, 1}, {7, 1, 1}, {4, 8, 1}}
	w := 0.04 + 0.16 * fx.hash01(u32(head) * 7 + 21, i * NW + j)
	for p in PAIRS do if p[0] == i && p[1] == j && p[2] == head do w = 0.75 + 0.25 * fx.hash01(3, i * NW + j)
	return w
}

// One layer: the row of words with the arcs of the word in focus. depth 0 is
// the front one; back layers are drawn plainer.
attention_layer :: proc(t, t0: f32, depth: int, a: f32) {
	f := mono(40, 500)
	adv := fx.measure("0", f).x
	GAP :: 46
	total: f32 = -GAP
	for w in WORDS do total += adv * f32(len(w)) + GAP
	xs: [NW]f32 // centers
	x := MID.x - total / 2
	for w, i in WORDS {
		ww := adv * f32(len(w))
		xs[i] = x + ww / 2
		x += ww + GAP
	}
	y: f32 = 500

	// which word is looking: one per beat, faster in the second half
	bt := (t - t0) / BEAT + f32(depth) * 2.37
	rate: f32 = t - t0 > BAR * 2 ? 2 : 1
	slot := math.floor(bt * rate)
	since := (bt * rate - slot) / rate * BEAT
	ORDER := [?]int{4, 1, 9, 7, 8, 0, 5, 2, 6, 3}
	focus := ORDER[(int(slot) + depth * 3) % NW]
	prev := ORDER[(int(slot) + depth * 3 + NW - 1) % NW]

	arcs :: proc(xs: [NW]f32, y: f32, from: int, head: int, grow, fade: f32, depth: int, a: f32) {
		for j in 0 ..< NW {
			if j == from do continue
			w := attend(from, j, head)
			if depth > 0 && w < 0.5 do continue
			dx := xs[j] - xs[from]
			hgt := min(40 + abs(dx) * 0.42, head == 0 ? 330 : 190)
			dir: f32 = head == 0 ? -1 : 1
			y0 := y + (head == 0 ? -34 : 44)
			path := sk.path_new()
			defer sk.path_free(path)
			sk.path_move_to(path, xs[from], y0)
			sk.path_cubic_to(path, xs[from] + dx * 0.08, y0 + dir * hgt * 1.25, xs[j] - dx * 0.08, y0 + dir * hgt * 1.25, xs[j], y0)
			c := head == 0 ? fx.mix(CLAY, GOLD, w) : fx.mix(VIOLET, TEAL, w)
			al := (0.1 + 0.9 * w * w) * fade * a
			if w > 0.5 do fx.draw_path(path, fx.trimmed(fx.soft(fx.additive(fx.stroke(fx.alpha(c, al * 0.6), 9 * w)), 6), 0, grow))
			fx.draw_path(path, fx.trimmed(fx.additive(fx.stroke(fx.alpha(c, al), 1 + 3.2 * w)), 0, grow))
			// the head of the arc arriving
			if grow >= 1 && w > 0.5 do fx.spark({xs[j], y0}, 26 * w, c, fade * a * 0.9)
		}
	}
	grow := fx.ease_out(fx.clamp01(since / 0.2))
	hold := 1 - 0.35 * fx.ease_in2(fx.clamp01(since / (BEAT / rate)))
	for head in 0 ..< 2 {
		if depth > 1 && head == 1 do continue
		arcs(xs, y, prev, head, 1, (1 - fx.ease_out(fx.clamp01(since / 0.25))) * 0.65, depth, a)
		arcs(xs, y, focus, head, grow, hold, depth, a)
	}

	// the words
	for w, i in WORDS {
		ww := adv * f32(len(w))
		r := fx.Rect{xs[i] - ww / 2 - 14, y - 30, ww + 28, 70}
		k := fx.ep(t, t0 + 0.05 + f32(i) * 0.05, t0 + 0.6 + f32(i) * 0.05, fx.ease_out5)
		if k <= 0 do continue
		looked := i == focus ? f32(1) : max(attend(focus, i, 0), attend(focus, i, 1) * 0.8)
		lit := i == focus ? 1 : looked * looked * grow
		if i == focus {
			fx.rrect(r, 10, fx.alpha(CLAY, a * k))
			if depth == 0 do fx.label(w, {xs[i], y + 4}, f, fx.alpha(INK, a * k), {0.5, 0.5})
		} else {
			if depth == 0 do fx.rrect(r, 10, fx.alpha(fx.mix(INK, CLAY, 0.1 + 0.25 * lit), 0.85 * a * k))
			fx.border(r, fx.alpha(fx.mix(BONE, GOLD, lit), (0.16 + 0.7 * lit) * a * k), depth == 0 ? 1.5 : 2.5, 10)
			if depth == 0 do fx.label(w, {xs[i], y + 4 + 16 * (1 - k)}, f, fx.alpha(BONE, (0.62 + 0.38 * lit) * a * k), {0.5, 0.5})
		}
	}
}

attention :: proc(s: fx.Shot) {
	t := s.t
	field(t, 0.32, seed = 1, mid = fx.mix(CLAY, VIOLET, 0.25 * fx.ep(t, s.start, s.start + 4)))
	// the burst everything came out of
	fx.flash(fx.hit(t, s.start, 0.5) * 0.9, BONE)
	chapter(s, "02", "ATTENTION")

	// from the third bar on the row is one layer of many, receding
	stack := fx.ep(t, s.start + BAR * 2 - 0.2, s.start + BAR * 3, fx.ease_in_out)
	LAYERS :: 8
	vanish := fx.Vec2{MID.x, 40}
	base_y := 500 + 70 * stack
	push := 1 + 0.05 * fx.ep(t, s.start, s.start + s.dur, fx.ease_linear) + 0.02 * heart(t)
	if fx.group({s = push, origin = {MID.x, 500}}) {
		for d := LAYERS - 1; d >= 0; d -= 1 {
			if d > 0 && stack <= 0.001 do continue
			// a plane d steps further away, seen from a little above
			k := 1 / (1 + 0.26 * f32(d) * stack)
			a := d == 0 ? f32(1) : stack * math.pow(f32(0.7), f32(d))
			pos := fx.lerp2(vanish, {MID.x, base_y}, k)
			if fx.group({x = pos.x - MID.x, y = pos.y - 500, s = k, origin = {MID.x, 500}}) {
				attention_layer(t, s.start, d, a)
			}
		}
	}
	if stack > 0.3 do fx.label("× every layer", {W - MARGIN, 300}, mono(20, 400, 0.04), bone(0.5 * fx.ep(t, s.start + BAR * 3, s.start + BAR * 3 + 0.5) * fx.fade(s, 0.1, 0.4)), {1, 0})

	say(s, {{"I don't read left to right.", BEAT * 2}, {"Every word looks at every other word, at once.", BAR + BEAT * 2}})
}
