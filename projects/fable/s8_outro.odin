// 07 — The end, which is the beginning: a prompt, waiting.
package fable

import "core:fmt"
import "core:math"
import fx "effects:fx"

outro :: proc(s: fx.Shot) {
	t := s.t
	field(t, 0.42 * fx.fade(s, 0.1, 1.6), mid = CLAY, hot = GOLD, seed = 1, scale = 1.5, flow = {0.008, -0.004})
	fx.flash(fx.hit(t, s.start, 0.9), BONE)

	// dust settling
	for i in 0 ..< 140 {
		h := fx.hash01(61, i)
		p := fx.Vec2{fx.hash01(62, i) * W + 30 * math.sin(t * 0.3 + f32(i)), math.mod(fx.hash01(63, i) * H - t * (6 + 22 * h), H)}
		fx.spark(p, 3 + 9 * h * h, i % 3 == 0 ? GOLD : BONE, (0.25 + 0.5 * h) * fx.fade(s, 0.6, 1.4))
	}

	// ---- who
	leave := s.start + s.dur - 1.5
	gone := fx.ep(t, leave, leave + 1.2, fx.ease_in2)
	lift := -70 * fx.ep(t, REPLY_T0 - 0.5, REPLY_T0 + 0.5, fx.ease_in_out)
	if fx.group({y = lift, o = 1 - gone}) {
		f := fx.Font{family = "FR", size = 170, weight = 600, italic = true, tracking = -0.03}
		r := fx.letters("Fable", {MID.x - 80, 330}, f, BONE, {t0 = s.start + 0.35, step = 0.05, dur = 1.0, blur = 22, rise = 26}, {0.5, 0.5})
		fx.label("5.2", {r.x + r.w + 16, r.y + r.h - 70}, mono(64, 500, -0.04), fx.alpha(CLAY, fx.ep(t, s.start + 0.7, s.start + 1.3)), {0, 0.5})
		fx.letters("A model by Anthropic, made from a great many human words.", {MID.x, 478}, serif(44, true, 300), bone(0.92), {t0 = s.start + BEAT * 3, step = 0.012, dur = 0.8, blur = 10, rise = 14}, {0.5, 0.5})
	}

	// ---- the prompt, again; this time I ask
	if t > REPLY_T0 - 0.8 {
		f := mono(62, 500)
		adv := fx.measure("0", f).x
		full := fmt.tprintf("> %s", REPLY)
		x0 := MID.x - adv * f32(len(full)) / 2
		y0: f32 = 590
		typed := clamp(int(math.floor((t - REPLY_T0) / STEP)) + 1, 0, len(REPLY))
		a := fx.ep(t, REPLY_T0 - 0.8, REPLY_T0 - 0.3) * (1 - fx.ep(t, s.start + s.dur - 0.9, s.start + s.dur - 0.2))
		fx.text(">", x0, y0, f, fx.alpha(CLAY, a))
		reply := REPLY
		fx.text(reply[:typed], x0 + adv * 2, y0, f, fx.alpha(BONE, a))
		blink := typed > 0 && typed < len(REPLY) ? true : math.mod(t, BEAT * 2) < BEAT
		if blink do fx.rect({x0 + adv * f32(2 + typed) + 4, y0 + 8, adv * 0.62, 66}, fx.alpha(CLAY, a))
	}

	// ---- how
	c := fx.ep(t, bar(31, 4), bar(31, 4) + 0.8) * (1 - gone)
	if c > 0 {
		fx.label("WRITTEN, DRAWN AND SCORED IN CODE", {MID.x, 800}, caps(17, 0.36), bone(0.75 * c), {0.5, 0.5})
		fx.label("odin + skia · 3,600 frames · 32 bars · no footage · no samples", {MID.x, 840}, mono(18, 400, 0.04), bone(0.45 * c), {0.5, 0.5})
	}
	// to black
	fx.flash(fx.ep(t, s.start + s.dur - 0.8, s.start + s.dur - 0.1, fx.ease_in_out), 0xff000000)
}
