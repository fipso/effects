// The things I make, a bar each: code, proofs, poems, sound — and this.
package fable

import "core:fmt"
import "core:math"
import fx "effects:fx"
import sk "effects:sk"

// What every one of these shares: its word, big, in the lower left, and a
// counter.
making :: proc(s: fx.Shot, word: string, n: int, c: fx.Color) {
	t := s.t
	f := fx.Font{family = "FR", size = 250, weight = 600, italic = true, tracking = -0.035}
	out := s.start + s.dur - 0.16
	fx.letters(word, {MARGIN - 8, H - 150}, f, BONE, {t0 = s.start, step = 0.022, dur = 0.42, rise = 90, blur = 18, out = out}, {0, 1})
	a := fx.win(t, s.start, s.start + s.dur, 0.15, 0.12)
	fx.label("THEN I MAKE", {MARGIN, 74}, caps(15, 0.24), bone(0.7 * a))
	fx.label(fmt.tprintf("0%d / 05", n), {W - MARGIN, 74}, caps(15, 0.24), fx.alpha(c, a), {1, 0})
	// a hard cut needs a frame of light
	fx.flash(fx.hit(t, s.start, 0.22) * 0.5, c)
}

// ---------------------------------------------------------------- code

FIB := [?]string {
	"// the nth Fibonacci number",
	"fib :: proc(n: int) -> int {",
	"\ta, b := 0, 1",
	"\tfor _ in 0 ..< n do a, b = b, a + b",
	"\treturn a",
	"}",
	"",
	"assert(fib(10) == 55)",
	"assert(fib(90) == 2880067194370816120)",
}

make_code :: proc(s: fx.Shot) {
	t, lt := s.t, s.lt
	k := kick(t)
	field(t, 0.4 + 0.2 * k, mid = TEAL, hot = BONE, seed = 12, scale = 1.4, flow = {0.05, 0})
	// the card, leaning in space
	card := fx.Rect{700, 190, 1060, 600}
	in_ := fx.ep(lt, 0, 0.45, fx.ease_out5)
	if fx.group({rx = 9 - 3 * lt, ry = -22 + 5 * lt + 3 * (1 - in_) * 10, persp = 1500, origin = fx.center(card), x = 240 * (1 - in_), o = fx.clamp01(in_ * 2) * fx.fade(s, 0, 0.12), s = 1 + 0.015 * k}) {
		fx.shadow(card, 22, 40, 90, 0, 0x90000000)
		fx.rrect(card, 22, 0xf2100e0d)
		fx.border(card, bone(0.22), 1.5, 22)
		for i in 0 ..< 3 do fx.circle({card.x + 34 + f32(i) * 26, card.y + 32}, 7, bone(0.22))
		fx.label("fib.odin", {card.x + card.w / 2, card.y + 32}, mono(19, 400, 0.04), bone(0.5), {0.5, 0.5})
		fx.hline(card.x, card.y + 62, card.w, bone(0.12))
		f := mono(30, 500)
		// the whole listing is typed in a little over two beats
		total := 0
		for l in FIB do total += len(l) + 1
		typed := int(fx.prog(lt, 0.1, BEAT * 2.6) * f32(total))
		y := card.y + 92
		cursor := fx.Vec2{card.x + 84, y}
		for l, i in FIB {
			if typed <= 0 do break
			n := min(typed, len(l))
			fx.label(fmt.tprintf("%d", i + 1), {card.x + 56, y + 2}, mono(22), bone(0.25), {1, 0})
			cols := code_line(l[:n], card.x + 84, y, f)
			adv := fx.measure("0", f).x
			cursor = {card.x + 84 + f32(cols) * adv, y}
			// the assertions pass on the last two beats
			if i >= 7 && l != "" {
				ok := fx.ep(lt, BEAT * (2.75 + f32(i - 7) * 0.5), BEAT * (2.75 + f32(i - 7) * 0.5) + 0.2)
				if ok > 0 {
					fx.rrect({card.x + 70, y - 4, card.w - 110, 46}, 8, fx.alpha(TEAL, 0.14 * ok))
					check({card.x + card.w - 74, y + 19}, 15, fx.alpha(TEAL, ok), ok)
				}
			}
			typed -= len(l) + 1
			y += 50
		}
		if lt < BEAT * 2.7 do fx.rect({cursor.x + 2, cursor.y + 2, 16, 38}, CLAY)
	}
	making(s, "code.", 1, TEAL)
}

// ---------------------------------------------------------------- proofs

// 1 + 3 + 5 + … + (2n − 1) = n², shown: every odd number is the L that
// grows a square by one.
make_proof :: proc(s: fx.Shot) {
	t, lt := s.t, s.lt
	k := kick(t)
	field(t, 0.35 + 0.2 * k, mid = VIOLET, hot = BONE, seed = 14, scale = 1.5, flow = {0, 0.04})
	N :: 7
	n := clamp(int(lt / (STEP * 2)) + 1, 1, N) // a new L every eighth
	since := lt - f32(n - 1) * STEP * 2
	cell: f32 = 76
	o := fx.Vec2{1010, 800} // bottom-left corner of the square; it grows up and right
	if fx.group({o = fx.fade(s, 0.05, 0.12), s = 1 + 0.02 * k, origin = {o.x + cell * 3.5, o.y - cell * 3.5}}) {
		for layer in 0 ..< n {
			fresh := layer == n - 1 && lt < f32(N) * STEP * 2 + 0.3
			c := layer % 2 == 0 ? BONE : VIOLET
			if fresh do c = GOLD
			count := 2 * layer + 1
			for j in 0 ..< count {
				// along the L: up the right side, then left along the top
				gx := j <= layer ? layer : 2 * layer - j
				gy := j <= layer ? j : layer
				pop := fresh ? fx.ease_back(fx.clamp01((since - f32(j) * 0.008) / 0.16)) : 1
				p := o + {(f32(gx) + 0.5) * cell, -(f32(gy) + 0.5) * cell}
				if fresh do fx.spark(p, 46, GOLD, 0.5 * (1 - fx.clamp01(since / 0.25)))
				fx.circle(p, 22 * pop, fx.alpha(c, fresh ? 1 : 0.9))
			}
		}
		// the side of the square, measured
		side := f32(n) * cell
		fx.hline(o.x, o.y + 26, side, bone(0.5), 1.5)
		fx.vline(o.x, o.y + 18, 16, bone(0.5), 1.5)
		fx.vline(o.x + side - 1.5, o.y + 18, 16, bone(0.5), 1.5)
		fx.label(fmt.tprintf("n = %d", n), {o.x + side / 2, o.y + 40}, mono(24, 500), bone(0.8), {0.5, 0})
	}
	// the sum so far
	b := fmt.tprintf("%d", 1)
	for i in 1 ..< n do b = fmt.tprintf("%s + %d", b, 2 * i + 1)
	eq := fmt.tprintf("%s = %d²", b, n)
	fx.label(eq, {W - MARGIN, 180}, mono(40, 500), BONE, {1, 0})
	q := fx.ep(lt, f32(N) * STEP * 2, f32(N) * STEP * 2 + 0.3)
	if q > 0 do fx.label("the sum of the first n odd numbers is n²", {W - MARGIN, 244}, mono(26, 500), fx.alpha(GOLD, q), {1, 0})
	making(s, "proofs.", 2, VIOLET)
}

// ---------------------------------------------------------------- poems

POEM := [?]string{"I have never seen the sea —", "only ten thousand ways", "of telling it."}

make_poem :: proc(s: fx.Shot) {
	t := s.t
	field(t, 0.3, mid = fx.mix(CLAY, ROSE, 0.5), hot = GOLD, seed = 17, scale = 1.8, flow = {0.01, 0.004})
	// a sea made of sines, the only kind I have
	for row in 0 ..< 16 {
		depth := f32(row) / 15 // 0 far, 1 near
		y := 560 + 430 * depth * depth
		amp := 4 + 26 * depth
		path := sk.path_new()
		defer sk.path_free(path)
		for i in 0 ..= 96 {
			x := f32(i) / 96 * W
			u := x / W * (10 - 5 * depth) + f32(row) * 1.7
			yy := y + amp * (math.sin(u + t * (0.5 + depth)) * 0.6 + math.sin(u * 2.3 - t * 0.8 + f32(row)) * 0.3 + math.sin(u * 0.6 + t * 0.3) * 0.4)
			if i == 0 do sk.path_move_to(path, x, yy)
			else do sk.path_line_to(path, x, yy)
		}
		a := (0.1 + 0.4 * depth) * fx.fade(s, 0.5, 0.3)
		fx.draw_path(path, fx.additive(fx.stroke(fx.alpha(fx.mix(ROSE, BONE, depth), a), 1 + 1.6 * depth)))
	}
	f := serif(92, true, 300)
	for l, i in POEM {
		t0 := s.start + 0.12 + f32(i) * BEAT * 1.6
		fx.letters(l, {MID.x + 60, 250 + f32(i) * 116}, f, BONE, {t0 = t0, step = 0.02, dur = 0.8, blur = 14, rise = 16, out = s.start + s.dur - 0.3}, {0.5, 0.5})
	}
	a := fx.win(t, s.start, s.start + s.dur, 0.15, 0.12)
	fx.label("THEN I MAKE", {MARGIN, 74}, caps(15, 0.24), bone(0.7 * a))
	fx.label("03 / 05", {W - MARGIN, 74}, caps(15, 0.24), fx.alpha(ROSE, a), {1, 0})
	fx.label("poems.", {MARGIN - 4, H - 150}, fx.Font{family = "FR", size = 120, weight = 600, italic = true, tracking = -0.03}, bone(0.9 * a), {0, 1})
	fx.flash(fx.hit(t, s.start, 0.3) * 0.5, ROSE)
}

// ---------------------------------------------------------------- sound

// The score itself, as it plays: its waveform bent into a ring, and the
// loudness of its bands around it.
make_sound :: proc(s: fx.Shot) {
	t := s.t
	k := kick(t)
	field(t, 0.4 + 0.25 * k, mid = GOLD, hot = BONE, seed = 19, scale = 1.3)
	sg := song()
	c := fx.Vec2{1260, 480}
	i0 := int(t * fx.RATE)
	lvl := fx.level_at(sg.level, t)
	R := 230 + 500 * fx.level_at(sg.low, t) * 0.5
	if fx.group({o = fx.fade(s, 0.06, 0.12)}) {
		// ---- bands: a hand-rolled spectrum (one resonator per bar) of the last 30 ms
		BANDS :: 72
		WIN :: 1440
		for b in 0 ..< BANDS {
			hz := 50 * math.pow(f32(220), f32(b) / (BANDS - 1))
			w := math.TAU * hz / fx.RATE
			re, im: f32
			for j := 0; j < WIN; j += 2 {
				idx := i0 - WIN + j
				if idx < 0 || idx >= len(sg.mix) do continue
				x := sg.mix[idx][0] + sg.mix[idx][1]
				hann := 0.5 - 0.5 * math.cos(math.TAU * f32(j) / WIN)
				re += x * hann * math.cos(w * f32(j))
				im += x * hann * math.sin(w * f32(j))
			}
			mag := math.sqrt(re * re + im * im) / WIN * 2
			v := fx.clamp01((20 * math.log10(mag + 1e-6) + 62) / 50)
			ang := f32(b) / BANDS * math.TAU - math.PI / 2
			d := fx.Vec2{math.cos(ang), math.sin(ang)}
			r0 := R + 44
			col := fx.mix(CLAY, GOLD, v)
			fx.line(c + d * r0, c + d * (r0 + 10 + 250 * v * v), fx.alpha(col, 0.35 + 0.65 * v), 7)
		}
		// ---- the wave, 40 ms of it, once around
		N :: 720
		SPAN :: 1920
		for pass in 0 ..< 2 {
			path := sk.path_new()
			defer sk.path_free(path)
			for i in 0 ..= N {
				idx := i0 + (i % N) * SPAN / N
				x: f32 = idx >= 0 && idx < len(sg.mix) ? (sg.mix[idx][0] + sg.mix[idx][1]) * 0.5 : 0
				ang := f32(i) / N * math.TAU - math.PI / 2
				// the seam fades to the circle so the ring closes
				seam := min(f32(i % N), f32(N - i % N)) / 40
				r := R + x * 110 * fx.clamp01(seam)
				p := c + fx.Vec2{math.cos(ang), math.sin(ang)} * r
				if i == 0 do sk.path_move_to(path, p.x, p.y)
				else do sk.path_line_to(path, p.x, p.y)
			}
			sk.path_close(path)
			if pass == 0 do fx.draw_path(path, fx.additive(fx.soft(fx.stroke(fx.alpha(GOLD, 0.6), 10), 8)))
			else do fx.draw_path(path, fx.additive(fx.stroke(BONE, 2.6)))
		}
		fx.spark(c, R * 0.9, GOLD, 0.25 + 0.5 * lvl)
		fx.label(fmt.tprintf("%.0f", BPM), c + {0, -12}, fx.Font{family = "FR", size = 150, weight = 300, italic = true}, BONE, {0.5, 0.5})
		fx.label("BPM · D MINOR · 0 SAMPLES", c + {0, 84}, caps(17, 0.3), bone(0.7), {0.5, 0.5})
	}
	making(s, "sound.", 4, GOLD)
}

// ---------------------------------------------------------------- and this

make_this :: proc(s: fx.Shot) {
	this_frame(s.t, s.lt, 1)
}

// "and this." — its own procedure, because the next scene shows it again
// inside the editor's preview.
this_frame :: proc(t, lt: f32, a: f32) {
	k := kick(t)
	fx.tunnel(fx.stage(), lt, CLAY, GOLD, speed = 2.2, twist = 0.1, ribs = 18, res = 0.6)
	fx.spark(MID, 520 + 120 * k, EMBER, 0.3 + 0.2 * k)
	f := fx.Font{family = "FR", size = 330, weight = 600, italic = true, tracking = -0.035}
	if fx.group({s = 1 + 0.03 * k + 0.05 * fx.prog(lt, 0, BAR), origin = MID}) {
		fx.letters("and this.", {MID.x, MID.y - 20}, f, BONE, {t0 = bar(24), step = 0.03, dur = 0.5, rise = 110, blur = 20}, {0.5, 0.5})
	}
	fx.label("THEN I MAKE", {MARGIN, 74}, caps(15, 0.24), bone(0.7 * a))
	fx.label("05 / 05", {W - MARGIN, 74}, caps(15, 0.24), fx.alpha(CLAY, a), {1, 0})
	fx.flash(fx.hit(t, bar(24), 0.22) * 0.5, CLAY)
}
